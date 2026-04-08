# Fleet Queue Subscription for lex-ollama

**Date**: 2026-04-07
**Status**: Design / RFC

---

## Problem

`lex-ollama` currently operates purely as a client library — it wraps the Ollama HTTP API and
returns results, but it never *subscribes* to any AMQP queue.  That means there is no way for the
Legion fleet to route LLM/embed work to an Ollama node over the message bus.  Every other
producer-side extension (`lex-openai`, `lex-claude`, etc.) publishes to the `extensions` exchange;
there is currently no Ollama-backed consumer on the other side.

---

## Goals

1. **Subscribe** — lex-ollama listens on a dedicated queue and processes `llm.request.*` messages
   sent by other fleet members (lex-llm-gateway, direct callers, etc.).
2. **Model-scoped routing keys** — each local model gets its own binding so traffic can be steered
   precisely without code-level dispatch logic.
3. **Minimal coupling** — the transport layer is guarded behind `const_defined?` so the gem still
   works as a standalone library (tests, scripts, irb) without any Legion runtime present.
4. **Consistent patterns** — follow the same `Transport/Queues`, `Transport/Messages`,
   `Transport/Exchanges`, `Actors` layout used by every other Legion extension.

---

## Routing Key Schema

```
llm.request.<provider>.<type>.<model>
```

| Segment    | Values                                      | Notes                               |
|------------|---------------------------------------------|-------------------------------------|
| `provider` | `ollama`                                    | always `ollama` for this extension  |
| `type`     | `chat`, `generate`, `embed`                 | maps 1-to-1 to a runner method      |
| `model`    | any Ollama model name (`:` → `.` sanitised) | e.g. `nomic-embed-text`, `qwen3.5.27b` |

### Examples

```
llm.request.ollama.embed.nomic-embed-text
llm.request.ollama.embed.mxbai-embed-large
llm.request.ollama.chat.qwen3.5.27b
llm.request.ollama.chat.llama3.2
llm.request.ollama.generate.llama3.2
```

Colons in model names (`qwen3.5:27b`) are converted to dots (`qwen3.5.27b`) because AMQP topic
routing keys use `.` as a word separator and `:` is not permitted.

---

## Queue Strategy: Dynamic Per-Model Queues

Each subscribed model gets its **own durable queue** bound to the `llm.request` topic exchange.

```
Exchange: llm.request  (topic, durable)
  ├── llm.request.ollama.embed.nomic-embed-text   → Queue: llm.request.ollama.embed.nomic-embed-text
  ├── llm.request.ollama.embed.mxbai-embed-large  → Queue: llm.request.ollama.embed.mxbai-embed-large
  ├── llm.request.ollama.chat.qwen3.5.27b         → Queue: llm.request.ollama.chat.qwen3.5.27b
  └── llm.request.ollama.chat.llama3.2            → Queue: llm.request.ollama.chat.llama3.2
```

**Why per-model queues instead of a wildcard queue?**

- Multiple nodes can each carry *different* model subsets.  A node with only `nomic-embed-text`
  should not compete for messages destined for `mxbai-embed-large`.
- RabbitMQ quorum queues + SAC (`x-single-active-consumer`) per queue let us cleanly support both
  load-balancing *and* exclusive-consumer topologies without any application-layer coordination.
- Routing key granularity lets lex-llm-gateway (or any sender) address a specific model precisely
  rather than relying on message-body dispatch.

---

## New Files

```
lib/legion/extensions/ollama/
  transport/
    exchanges/
      llm_request.rb          # Topic exchange: 'llm.request'
    queues/
      model_request.rb        # Parametric queue class — one instance per (type, model) tuple
    messages/
      llm_response.rb         # Response message published back to reply_to
  actors/
    model_worker.rb           # Subscription actor — one per registered model
  runners/
    fleet.rb                  # NEW: fleet request dispatcher (chat/embed/generate dispatch)
  transport.rb                # Transport module wiring for the extension

spec/legion/extensions/ollama/
  transport/
    exchanges/llm_request_spec.rb
    queues/model_request_spec.rb
    messages/llm_response_spec.rb
  actors/model_worker_spec.rb
  runners/fleet_spec.rb
```

---

## Detailed Design

### `Transport::Exchanges::LlmRequest`

```ruby
module Legion::Extensions::Ollama::Transport::Exchanges
  class LlmRequest < Legion::Transport::Exchange
    def exchange_name = 'llm.request'
    def default_type  = 'topic'
  end
end
```

A single `topic` exchange shared by all AI provider extensions.  If `lex-openai` or `lex-claude`
declare the same exchange name with the same options, RabbitMQ deduplicates (no `PreconditionFailed`
because parameters match).

---

### `Transport::Queues::ModelRequest`

A **parametric queue** — one Ruby class, instantiated N times with different `(type, model)` pairs.

```ruby
module Legion::Extensions::Ollama::Transport::Queues
  class ModelRequest < Legion::Transport::Queue
    def initialize(request_type:, model:, **)
      @request_type = request_type.to_s
      @model        = sanitise_model(model)
      super(**)
    end

    def queue_name
      "llm.request.ollama.#{@request_type}.#{@model}"
    end

    def queue_options
      { durable: true, arguments: { 'x-queue-type': 'quorum' } }
    end

    private

    def sanitise_model(name)
      name.to_s.tr(':', '.')
    end
  end
end
```

The `queue_name` mirrors the routing key exactly, which keeps bindings trivially readable in the
RabbitMQ management UI.

---

### `Transport::Messages::LlmResponse`

Sent back to `reply_to` (if present) after processing.

```ruby
module Legion::Extensions::Ollama::Transport::Messages
  class LlmResponse < Legion::Transport::Message
    def routing_key  = @options[:reply_to]
    def exchange     = Legion::Transport::Exchanges::Agent   # direct reply via default exchange
    def encrypt?     = false
    def message
      {
        correlation_id: @options[:correlation_id],
        result:         @options[:result],
        usage:          @options[:usage],
        model:          @options[:model],
        provider:       'ollama',
        status:         @options[:status]
      }
    end
  end
end
```

---

### `Runners::Fleet`

New runner module.  Dispatches inbound AMQP payloads to the appropriate Ollama method and
optionally publishes a reply.

```ruby
module Legion::Extensions::Ollama::Runners::Fleet
  module_function

  # Primary entry point called by the actor.
  def handle_request(model:, request_type: 'chat', reply_to: nil,
                     correlation_id: nil, **payload)
    result = dispatch(model: model, request_type: request_type, **payload)
    publish_reply(reply_to, correlation_id, result) if reply_to
    result
  end

  private

  def dispatch(model:, request_type:, **payload)
    client = Legion::Extensions::Ollama::Client.new

    case request_type.to_s
    when 'embed'
      client.embed(model: model, input: payload[:input] || payload[:text])
    when 'generate'
      client.generate(model: model, prompt: payload[:prompt], **payload.slice(:options, :system))
    else  # 'chat' and anything else
      client.chat(model: model, messages: payload[:messages],
                  **payload.slice(:tools, :format, :options))
    end
  rescue StandardError => e
    { result: nil, status: 500, error: e.message }
  end

  def publish_reply(reply_to, correlation_id, result)
    return unless defined?(Legion::Transport)

    Transport::Messages::LlmResponse.new(
      reply_to:       reply_to,
      correlation_id: correlation_id,
      **result
    ).publish
  rescue StandardError
    nil  # never let a broken reply kill the ack
  end
end
```

---

### `Actors::ModelWorker`

One actor instance per `(type, model)` pair.  Overrides `queue` to return the
pre-instantiated `ModelRequest` queue bound to its specific routing key.

```ruby
module Legion::Extensions::Ollama::Actor
  class ModelWorker < Legion::Extensions::Actors::Subscription
    attr_reader :request_type, :model_name

    def initialize(request_type:, model:, **)
      @request_type = request_type.to_s
      @model_name   = model.to_s
      super(**)
    end

    def runner_class    = Legion::Extensions::Ollama::Runners::Fleet
    def runner_function = 'handle_request'
    def use_runner?     = false

    # Override to use a model-scoped queue instead of the default convention-based one.
    def queue
      @queue_class ||= begin
        Transport::Queues::ModelRequest.new(
          request_type: @request_type,
          model:        @model_name
        ).tap do |q|
          exchange = Transport::Exchanges::LlmRequest.new
          routing_key = "llm.request.ollama.#{@request_type}.#{@model_name.tr(':', '.')}"
          q.bind(exchange, routing_key: routing_key)
        end
      end
    end

    # Injects request_type + model into every message so Fleet#handle_request
    # always has them, even if the sender omitted them.
    def process_message(payload, metadata, delivery_info)
      msg = super
      msg[:request_type] ||= @request_type
      msg[:model]        ||= @model_name
      msg
    end
  end
end
```

---

### `transport.rb` (extension-level wiring)

```ruby
require 'legion/extensions/transport'

module Legion::Extensions::Ollama::Transport
  extend Legion::Extensions::Transport

  # No additional e_to_q here — all bindings are created dynamically by
  # ModelWorker#queue.  The exchange declaration is enough for topology mode.
  def self.additional_e_to_q = []
end
```

---

### Settings / Model Registration

Models to subscribe for are read from `Legion::Settings` at boot:

```yaml
# legion.yml (or legion-settings)
legion:
  ollama:
    host: "http://localhost:11434"
    subscriptions:
      - type: embed
        model: nomic-embed-text
      - type: embed
        model: mxbai-embed-large
      - type: chat
        model: "qwen3.5:27b"
      - type: chat
        model: llama3.2
      - type: generate
        model: llama3.2
```

The extension's `Core` lifecycle hook reads this list and spawns one `ModelWorker` actor per entry.

---

### `ollama.rb` changes (main extension file)

Add the new requires (guarded so the gem still loads without Legion core):

```ruby
require 'legion/extensions/ollama/runners/fleet'

if Legion::Extensions.const_defined?(:Core)
  require 'legion/extensions/ollama/transport/exchanges/llm_request'
  require 'legion/extensions/ollama/transport/queues/model_request'
  require 'legion/extensions/ollama/transport/messages/llm_response'
  require 'legion/extensions/ollama/transport/transport'
  require 'legion/extensions/ollama/actors/model_worker'
end
```

---

## Transport Topology Diagram

```
Publisher (lex-llm-gateway / any Legion node)
  │
  │  publish routing_key: "llm.request.ollama.embed.nomic-embed-text"
  ▼
Exchange: llm.request  [topic, durable]
  │
  ├─── binding: llm.request.ollama.embed.nomic-embed-text
  │         ▼
  │    Queue: llm.request.ollama.embed.nomic-embed-text  [quorum, durable]
  │         ▼
  │    ModelWorker(type: embed, model: nomic-embed-text)
  │         ▼
  │    Runners::Fleet.handle_request(...)
  │         ▼
  │    Ollama::Client#embed(model: 'nomic-embed-text', ...)
  │         ▼
  │    LlmResponse.publish → reply_to queue
  │
  ├─── binding: llm.request.ollama.embed.mxbai-embed-large
  │         ▼  [similar chain]
  │
  └─── binding: llm.request.ollama.chat.qwen3.5.27b
            ▼  [similar chain]
```

---

## What Stays Unchanged

| Component               | Status       | Reason                                         |
|-------------------------|--------------|------------------------------------------------|
| `Runners::Chat`         | Unchanged    | Still used directly + via fleet               |
| `Runners::Embeddings`   | Unchanged    | Still used directly + via fleet               |
| `Runners::Completions`  | Unchanged    | Still used directly + via fleet               |
| `Runners::Models`       | Unchanged    | Not a fleet-dispatched concern                |
| `Runners::S3Models`     | Unchanged    | Separate distribution concern                 |
| `Runners::Blobs`        | Unchanged    | Internal implementation detail                |
| `Helpers::Client`       | Unchanged    | Faraday factory, no transport coupling        |
| `Helpers::Errors`       | Unchanged    | Retry logic, no transport coupling            |
| `Helpers::Usage`        | Unchanged    | Token normalisation, no transport coupling    |
| `Client` class          | Unchanged    | Standalone HTTP client — no AMQP dependency   |
| All existing specs      | Unchanged    | 82 passing examples must remain green         |

---

## Open Questions

1. **`x-single-active-consumer` per queue?**  If multiple ollama nodes carry the same model, do we
   want them to compete (round-robin, no SAC) or have a single active + hot-standby (SAC=true)?
   Default proposal: **no SAC** (any subscribed node can serve), matches how lex-conditioner works.

2. **Wildcard subscription?**  Should there be an opt-in `llm.request.ollama.#` catch-all queue for
   nodes that want to handle *any* ollama traffic?  Useful for dev/single-node setups.  Proposal:
   add as a separate `ModelWorker`-compatible setting (`type: '*', model: '*'`) with a wildcard
   routing key binding.

3. **Streaming over AMQP?**  The current design returns the full accumulated response in a single
   reply message (non-streaming).  Streaming responses over AMQP (chunked delta messages) is
   possible but significantly more complex — deferred to a future phase.

4. **`request_type` in routing key vs message body?**  Currently the routing key embeds the type
   (`chat`, `embed`, `generate`).  The message body should also carry it so `Fleet#handle_request`
   can dispatch without needing to parse the delivery routing key.  The actor injects it from its
   own instance vars — this is the agreed approach.

---

## Implementation Phases

| Phase | Scope                                                           | New specs |
|-------|-----------------------------------------------------------------|-----------|
| 1     | `Transport::Exchanges::LlmRequest` + `Transport::Queues::ModelRequest` | 2 files   |
| 2     | `Runners::Fleet` + `Transport::Messages::LlmResponse`          | 2 files   |
| 3     | `Actors::ModelWorker` + `transport.rb` + settings loading       | 2 files   |
| 4     | `ollama.rb` integration wiring + CLAUDE.md update               | —         |

Each phase is independently reviewable/mergeable.

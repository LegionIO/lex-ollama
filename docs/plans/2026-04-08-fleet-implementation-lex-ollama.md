# Fleet Implementation Plan: lex-ollama Worker Side

**Date**: 2026-04-08
**Author**: Matthew Iverson (@Esity)
**Status**: Ready for implementation
**Related**:
- [Fleet Architecture Design](2026-04-08-fleet-llm-architecture-design.md)
- [Fleet Wire Protocol](2026-04-08-fleet-wire-protocol.md)
- [S3 Model Distribution Design](2026-04-01-s3-model-distribution-design.md)

---

## Overview

This document specifies every change required in lex-ollama to implement the fleet worker
side of the LLM fleet architecture. It covers transport classes, the subscription actor,
the fleet runner, configuration schema, test plan, and standalone mode behavior.

The fleet **dispatch** side (publishing to `llm.request`, managing reply queues, handling
`basic.return`/`basic.nack`, tier routing) lives in `legion-llm` and is not covered here.
This plan covers only what runs on the worker node: receive request → call Ollama → send
reply.

---

## Prerequisites

The following `legion-llm` Day-0 deliverables must exist before any lex-ollama fleet code
can be tested end-to-end:

1. `Legion::LLM::Transport::Message` — LLM base message class with `message_context`
   propagation, `llm_headers`, `context_headers`, `LLM_ENVELOPE_KEYS`
2. `Legion::LLM::Fleet::Exchange` — declares `llm.request` topic exchange (durable)
3. `Legion::LLM::Fleet::Request` — inherits LLM base, `type: 'llm.fleet.request'`,
   `message_id_prefix: 'req'`, priority mapping, `reply_to`, `expiration`
4. `Legion::LLM::Fleet::Response` — inherits LLM base, `type: 'llm.fleet.response'`,
   `message_id_prefix: 'resp'`, publishes via default exchange
5. `Legion::LLM::Fleet::Error` — inherits LLM base, `type: 'llm.fleet.error'`,
   `message_id_prefix: 'err'`, `x-legion-fleet-error` header

Unit tests for lex-ollama components can use doubles for these classes. Integration tests
require the legion-llm Day-0 deliverables to be present in the load path.

---

## Current State vs. Target State

The fleet skeleton already exists in the codebase. The following files are present but
contain gaps that must be corrected:

| File | Current State | Required Change |
|------|---------------|-----------------|
| `transport/exchanges/llm_request.rb` | Defines `llm.request` inline | Must delegate to `Legion::LLM::Fleet::Exchange` |
| `transport/queues/model_request.rb` | Quorum queue, wrong options | Classic auto-delete, `x-max-priority: 10` argument |
| `transport/messages/llm_response.rb` | Inherits base `Legion::Transport::Message`, custom `#message` | Inherit `Legion::LLM::Fleet::Response`, set `app_id: 'lex-ollama'`, carry `message_context` |
| `actors/model_worker.rb` | No `prefetch`, no `consumer_priority` | Add `prefetch(1)`, wire `consumer_priority` from settings |
| `runners/fleet.rb` | No `message_context` propagation, no wire-protocol fields | Propagate `message_context`, build full response envelope, publish `LlmError` on failure |

The following files require **no changes** to their existing structure:
- `transport.rb` — guard logic and `additional_e_to_q` are correct
- `ollama.rb` — standalone guard is correct
- All existing runners (`Chat`, `Completions`, `Embeddings`, `Models`, `Blobs`,
  `S3Models`, `Version`)
- `helpers/client.rb`, `helpers/errors.rb`, `helpers/usage.rb`
- `client.rb`

---

## Implementation Order

Steps are ordered by dependency. Each step can be implemented and tested in isolation.
Steps 1–3 have no inter-dependencies (only on legion-llm Day-0). Steps 4–5 depend on 1–3.

```
legion-llm Day-0 (external prerequisite)
  └── Step 1: Transport::Exchanges::LlmRequest  (delegates to Fleet::Exchange)
  └── Step 2: Transport::Queues::ModelRequest   (classic auto-delete + x-max-priority)
  └── Step 3: Transport::Messages::LlmResponse  (inherits Fleet::Response, app_id)
        │
        └── Step 4: Runners::Fleet              (message_context, full envelope, error path)
              │
              └── Step 5: Actor::ModelWorker    (prefetch, consumer_priority, settings wiring)
```

Step 6 (specs) runs after each step — write tests alongside the implementation, not after.

---

## Step 1: Transport::Exchanges::LlmRequest

**File**: `lib/legion/extensions/ollama/transport/exchanges/llm_request.rb`

### Current Implementation

```ruby
class LlmRequest < Legion::Transport::Exchange
  def exchange_name = 'llm.request'
  def default_type  = 'topic'
end
```

### Problem

This class independently declares exchange properties that are canonical in
`Legion::LLM::Fleet::Exchange`. If `Fleet::Exchange` changes exchange name or durability,
lex-ollama would silently diverge. Workers that declare a conflicting exchange definition
will fail with a RabbitMQ precondition error if the exchange already exists with different
attributes.

### Required Change

Delegate to `Legion::LLM::Fleet::Exchange` by inheriting from it. `LlmRequest` becomes a
thin alias — its only purpose is to exist in the `Ollama::Transport::Exchanges` namespace
so that `Transport.additional_e_to_q` and topology introspection can find it without
knowing about legion-llm internals.

### Target Implementation

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Exchanges
          # Thin alias that delegates exchange definition to Legion::LLM::Fleet::Exchange.
          # This class exists solely so Ollama::Transport topology introspection has a
          # local reference without importing legion-llm internals directly.
          class LlmRequest < Legion::LLM::Fleet::Exchange
          end
        end
      end
    end
  end
end
```

### Method Signatures (inherited, no overrides needed)

| Method | Source | Returns |
|--------|--------|---------|
| `#exchange_name` | `Legion::LLM::Fleet::Exchange` | `'llm.request'` |
| `#default_type` | `Legion::LLM::Fleet::Exchange` | `'topic'` |

### Spec Changes

The existing spec already tests `exchange_name` and `default_type` directly on the instance.
Those two examples remain valid. Add one example verifying the inheritance relationship:

```ruby
it 'is a subclass of Legion::LLM::Fleet::Exchange' do
  expect(described_class.ancestors).to include(Legion::LLM::Fleet::Exchange)
end
```

Remove the existing `it 'is a subclass of Legion::Transport::Exchange'` example — that
relationship is now tested transitively through `Fleet::Exchange`.

---

## Step 2: Transport::Queues::ModelRequest

**File**: `lib/legion/extensions/ollama/transport/queues/model_request.rb`

### Current Implementation

```ruby
def queue_options
  { durable: true, arguments: { 'x-queue-type': 'quorum' } }
end
```

### Problems

1. **Quorum queues cannot be auto-delete** — RabbitMQ rejects the combination. The fleet
   architecture requires auto-delete queues so that `mandatory: true` publishes receive
   `basic.return` when all workers for a model disconnect.
2. **`x-max-priority` must be a queue argument** — for classic queues, this cannot be set
   via policy alone. Workers must declare it at queue creation time.
3. **`durable: true`** — fleet request queues are ephemeral. Durable queues survive broker
   restarts and accumulate stale messages. Auto-delete queues are self-cleaning.

### Required Change

Switch to classic auto-delete with `x-max-priority: 10`.

### Target Implementation

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Queues
          # Parametric queue — one instance per (request_type, model) tuple.
          #
          # queue_name mirrors the routing key exactly so bindings are self-documenting
          # in the RabbitMQ management UI, e.g.:
          #   llm.request.ollama.embed.nomic-embed-text
          #   llm.request.ollama.chat.qwen3.5.27b
          #
          # Queue strategy:
          #   - classic (not quorum): quorum queues cannot be auto-delete
          #   - auto_delete: true — queue deletes when last consumer disconnects + queue empties,
          #     enabling basic.return feedback to publishers via mandatory: true
          #   - x-max-priority: 10 — must be a queue argument at declaration time for classic
          #     queues; policies handle max-length and overflow externally
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
              {
                durable:     false,
                auto_delete: true,
                arguments:   { 'x-max-priority' => 10 }
              }
            end

            # Disable dead-letter exchange provisioning. The base class
            # default_options always adds x-dead-letter-exchange when
            # dlx_enabled returns true. Fleet queues are ephemeral
            # (auto-delete) and must not provision persistent DLX queues.
            def dlx_enabled
              false
            end

            private

            def sanitise_model(name)
              name.to_s.tr(':', '.')
            end
          end
        end
      end
    end
  end
end
```

### Method Signatures

| Method | Signature | Returns | Notes |
|--------|-----------|---------|-------|
| `#initialize` | `(request_type:, model:, **)` | `ModelRequest` | Sanitises model, calls `super` |
| `#queue_name` | `()` | `String` | `"llm.request.ollama.#{type}.#{model}"` |
| `#queue_options` | `()` | `Hash` | `{ durable: false, auto_delete: true, arguments: { 'x-max-priority' => 10 } }` |
| `#dlx_enabled` | `()` | `false` | Disables dead-letter exchange provisioning (base class default is `true`) |
| `#sanitise_model` (private) | `(name)` | `String` | Replaces `:` with `.` |

### Spec Changes

Replace the two existing `#queue_options` examples:

```ruby
describe '#queue_options' do
  let(:instance) do
    q = queue_class.allocate
    q.instance_variable_set(:@request_type, 'embed')
    q.instance_variable_set(:@model, 'nomic-embed-text')
    q
  end

  it 'is not durable' do
    expect(instance.queue_options[:durable]).to be(false)
  end

  it 'is auto-delete' do
    expect(instance.queue_options[:auto_delete]).to be(true)
  end

  it 'sets x-max-priority to 10' do
    expect(instance.queue_options.dig(:arguments, 'x-max-priority')).to eq(10)
  end

  it 'does not set x-queue-type quorum' do
    expect(instance.queue_options.dig(:arguments, :'x-queue-type')).to be_nil
  end
end
```

---

## Step 3: Transport::Messages::LlmResponse

**File**: `lib/legion/extensions/ollama/transport/messages/llm_response.rb`

### Current Implementation

```ruby
class LlmResponse < Legion::Transport::Message
  def routing_key  = @options[:reply_to]
  def exchange     = Legion::Transport::Exchanges::Agent
  def encrypt?     = false
  def message
    {
      correlation_id: @options[:correlation_id],
      result:         @options[:result],
      usage:          @options[:usage],
      model:          @options[:model],
      provider:       'ollama',
      status:         @options[:status] || 200
    }
  end
end
```

### Problems

1. **Wrong base class** — inherits `Legion::Transport::Message` directly, bypassing
   `Legion::LLM::Fleet::Response` which handles `message_context` propagation, `type`
   property (`'llm.fleet.response'`), `message_id_prefix` (`'resp'`), correct
   `correlation_id` semantics, and the default-exchange `publish` override.
2. **Wrong exchange** — points to `Legion::Transport::Exchanges::Agent`. Fleet responses
   must publish to the AMQP default exchange `''` with `reply_to` as the routing key.
   `Legion::LLM::Fleet::Response#publish` handles this.
3. **Missing `message_context`** — the body omits `message_context`, breaking end-to-end
   tracing for all downstream metering and audit consumers.
4. **Wrong `app_id`** — the base class defaults to `'legion'`. Fleet responses from a
   worker must carry `app_id: 'lex-ollama'` so ReplyDispatcher and audit records know
   which worker handled the request.
5. **Missing wire protocol fields** — `id`, `response_message_id`, `routing`, `tokens`,
   `stop`, `cost`, `timestamps`, `audit` are all absent from the body.
6. **Custom `#message` instead of `LLM_ENVELOPE_KEYS` stripping** — the LLM base class
   uses `@options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)` to build the body, letting
   callers pass any fields they want included without hardcoding them here.

### Required Change

Inherit `Legion::LLM::Fleet::Response`. Override `app_id` to return `'lex-ollama'`.
Remove the custom `#message`, `#exchange`, `#encrypt?`, and `#routing_key` overrides —
they are all handled correctly by the parent class.

### Target Implementation

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Messages
          # Published back to the caller's reply_to queue after a fleet request is processed.
          #
          # Inherits Legion::LLM::Fleet::Response which:
          #   - sets type: 'llm.fleet.response'
          #   - sets routing_key to @options[:reply_to]
          #   - publishes via AMQP default exchange ('')
          #   - propagates message_context into body and headers
          #   - generates message_id with 'resp_' prefix
          #
          # This class only overrides app_id so audit records and the wire protocol
          # correctly identify lex-ollama as the worker component.
          class LlmResponse < Legion::LLM::Fleet::Response
            def app_id
              'lex-ollama'
            end
          end
        end
      end
    end
  end
end
```

### Method Signatures

| Method | Signature | Returns | Notes |
|--------|-----------|---------|-------|
| `#app_id` | `()` | `'lex-ollama'` | Identifies the worker component |
| `#type` | `()` (inherited) | `'llm.fleet.response'` | From `Fleet::Response` |
| `#routing_key` | `()` (inherited) | `@options[:reply_to]` | From `Fleet::Response` |
| `#priority` | `()` (inherited) | `0` | From `Fleet::Response` |
| `#message_id` | `()` (inherited) | `"resp_<uuid>"` | From LLM base |
| `#correlation_id` | `()` (inherited) | `@options[:fleet_correlation_id]` | From LLM base |
| `#publish` | `(options = @options)` (inherited) | `nil` | Publishes via `channel.default_exchange` |
| `#message` | `()` (inherited) | `Hash` | `@options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)` |

### Caller Contract

`Runners::Fleet#publish_reply` must pass the correct keys when constructing `LlmResponse`.
The LLM base class strips `LLM_ENVELOPE_KEYS` from the body automatically. The caller
must pass:

```ruby
LlmResponse.new(
  # Envelope fields (stripped from body, used as AMQP properties)
  reply_to:             request[:reply_to],
  fleet_correlation_id: request[:correlation_id],  # NOTE: fleet_correlation_id, not correlation_id
  message_context:      request[:message_context],
  provider:             'ollama',
  model:                model,
  request_type:         request_type,

  # Body fields (included in JSON, not stripped)
  message:       { role: 'assistant', content: ... },  # for chat
  # OR
  embeddings:    [...],                                  # for embed
  # OR
  response:      '...',                                  # for generate
  tokens:        { input: N, output: M, total: T },
  stop:          { reason: 'stop' },
  routing:       { provider: 'ollama', model: model, latency_ms: ms },
  timestamps:    { received: t0, provider_start: t1, provider_end: t2, returned: t3 },
  app_id:        'lex-ollama'
)
```

The `fleet_correlation_id` key is critical: the LLM base `#correlation_id` method reads
`@options[:fleet_correlation_id]`, not `:correlation_id`, to avoid collision with the
Legion task tracking `correlation_id` which maps to `parent_id`/`task_id`.

### Spec Changes

The existing spec for `LlmResponse` tests the old `#message` structure. It must be
rewritten entirely:

```ruby
RSpec.describe Legion::Extensions::Ollama::Transport::Messages::LlmResponse do
  subject(:message_class) { described_class }

  it 'inherits from Legion::LLM::Fleet::Response' do
    expect(message_class.ancestors).to include(Legion::LLM::Fleet::Response)
  end

  describe '#app_id' do
    it 'returns lex-ollama' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, {})
      expect(instance.app_id).to eq('lex-ollama')
    end
  end

  describe '#type' do
    it 'returns llm.fleet.response' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, {})
      expect(instance.type).to eq('llm.fleet.response')
    end
  end

  describe '#routing_key' do
    it 'returns the reply_to value' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, { reply_to: 'llm.fleet.reply.abc' })
      expect(instance.routing_key).to eq('llm.fleet.reply.abc')
    end
  end

  describe '#priority' do
    it 'returns 0' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, {})
      expect(instance.priority).to eq(0)
    end
  end
end
```

---

## Step 4: Runners::Fleet

**File**: `lib/legion/extensions/ollama/runners/fleet.rb`

### Current Implementation Summary

- `handle_request(model:, request_type:, reply_to:, correlation_id:, **payload)` — dispatches
  by `request_type`, calls `publish_reply` if `reply_to` is present
- `dispatch(model:, request_type:, **payload)` — calls `Client#embed`, `#generate`, or `#chat`
- `publish_reply(reply_to, correlation_id, result)` — constructs `LlmResponse` and publishes

### Problems

1. **No `message_context` propagation** — `message_context` in the inbound payload is
   silently discarded. It must be copied verbatim into the reply envelope.
2. **No error reply** — when `dispatch` raises, `handle_request` returns `{ status: 500,
   error: ... }` to the actor but never sends anything back to the caller's `reply_to`
   queue. The caller's `future.value!(timeout)` will wait until timeout, then fail with
   `:fleet_timeout` instead of the faster `:fleet_worker_error`.
3. **`publish_reply` signature is positional** — this makes the call site fragile and the
   method hard to extend. Switch to keyword arguments.
4. **`LlmResponse` caller contract mismatch** — after Step 3, `LlmResponse` inherits
   `Fleet::Response` and requires `fleet_correlation_id:` (not `correlation_id:`), and
   needs `message_context:`, `provider:`, `model:`, `request_type:` passed separately.
5. **No `stream: true` rejection** — v1 does not support streaming over fleet. A request
   with `stream: true` should receive an error reply immediately rather than silently
   producing a non-streaming response.
6. **No `received_at` timestamp** — the response `timestamps` block requires a
   `received` timestamp. This must be captured at the start of `handle_request`.
7. **`host:` not wired from settings** — `Client.new` is called without a host. In
   standalone mode this defaults to `localhost:11434` which is correct, but when settings
   specify a different host, the fleet runner ignores it.

### Target Implementation

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Runners
        # Fleet runner — handles inbound AMQP LLM request messages and dispatches
        # them to the appropriate Ollama::Client method based on request_type.
        #
        # Called by Actor::ModelWorker with use_runner? = false.
        module Fleet
          module_function

          # Primary entry point called by the subscription actor.
          #
          # @param model [String] Ollama model name, e.g. "nomic-embed-text"
          # @param request_type [String] "chat", "embed", or "generate"
          # @param reply_to [String, nil] routing key for the reply queue (RPC pattern)
          # @param correlation_id [String, nil] fleet correlation ID, echoed back in reply
          # @param message_context [Hash] tracing context — copied verbatim into the reply
          # @param payload [Hash] remaining message keys passed to the Ollama client
          def handle_request(model:, request_type: 'chat', reply_to: nil,
                             correlation_id: nil, message_context: {}, **payload)
            received_at = Time.now.utc

            if payload[:stream]
              publish_error(
                reply_to:        reply_to,
                correlation_id:  correlation_id,
                message_context: message_context,
                model:           model,
                request_type:    request_type,
                error:           {
                  code:      'unsupported_streaming',
                  message:   'Streaming over the fleet AMQP bus is not supported in v1',
                  retriable: false,
                  category:  'validation',
                  provider:  'ollama'
                }
              )
              return { result: nil, status: 422, error: 'unsupported_streaming' }
            end

            result = dispatch(model: model, request_type: request_type, **payload)
            returned_at = Time.now.utc

            if reply_to
              publish_reply(
                reply_to:        reply_to,
                correlation_id:  correlation_id,
                message_context: message_context,
                model:           model,
                request_type:    request_type,
                result:          result,
                received_at:     received_at,
                returned_at:     returned_at
              )
            end

            result
          end

          # Dispatch to the correct Ollama client method by request_type.
          #
          # @return [Hash] { result: body, status: code } or { result: nil, status: 500, error: msg }
          def dispatch(model:, request_type:, **payload)
            host   = ollama_host
            ollama = Legion::Extensions::Ollama::Client.new(host: host)

            case request_type.to_s
            when 'embed'
              input = payload[:input] || payload[:text]
              ollama.embed(model: model, input: input,
                           **payload.slice(:truncate, :options, :keep_alive, :dimensions))
            when 'generate'
              ollama.generate(model: model, prompt: payload[:prompt],
                              **payload.slice(:images, :format, :options, :system, :keep_alive))
            else
              ollama.chat(model: model, messages: payload[:messages],
                          **payload.slice(:tools, :format, :options, :keep_alive, :think))
            end
          rescue StandardError => e
            { result: nil, usage: {}, status: 500, error: e.message }
          end

          # Publish a successful fleet response to the caller's reply_to queue.
          # Errors are swallowed so the AMQP ack path is never blocked by a broken reply.
          #
          # @param reply_to [String] routing key for the reply queue
          # @param correlation_id [String] fleet correlation ID from the request
          # @param message_context [Hash] tracing context copied from the request
          # @param model [String] Ollama model name
          # @param request_type [String] 'chat', 'embed', or 'generate'
          # @param result [Hash] { result: body, status: code } from dispatch
          # @param received_at [Time] when handle_request was entered
          # @param returned_at [Time] when dispatch completed
          def publish_reply(reply_to:, correlation_id:, message_context:, model:,
                            request_type:, result:, received_at:, returned_at:)
            return unless defined?(Legion::Transport)

            body   = result[:result] || {}
            usage  = result[:usage] || {}
            status = result[:status] || 200
            latency_ms = ((returned_at - received_at) * 1000).round

            Transport::Messages::LlmResponse.new(
              # Envelope fields (stripped from body by LLM_ENVELOPE_KEYS)
              reply_to:             reply_to,
              fleet_correlation_id: correlation_id,
              message_context:      message_context,
              provider:             'ollama',
              model:                model,
              request_type:         request_type,
              app_id:               'lex-ollama',

              # Body fields
              **build_response_body(
                request_type: request_type,
                body:         body,
                usage:        usage,
                status:       status,
                model:        model,
                latency_ms:   latency_ms,
                received_at:  received_at,
                returned_at:  returned_at
              )
            ).publish
          rescue StandardError
            nil
          end

          # Publish a fleet error to the caller's reply_to queue.
          # Errors are swallowed so the AMQP ack path is never blocked.
          #
          # @param reply_to [String, nil] routing key for the reply queue
          # @param correlation_id [String, nil] fleet correlation ID from the request
          # @param message_context [Hash] tracing context copied from the request
          # @param model [String] Ollama model name
          # @param request_type [String] 'chat', 'embed', or 'generate'
          # @param error [Hash] { code:, message:, retriable:, category:, provider: }
          def publish_error(reply_to:, correlation_id:, message_context:, model:,
                            request_type:, error:)
            return unless reply_to
            return unless defined?(Legion::Transport)

            Legion::LLM::Fleet::Error.new(
              reply_to:             reply_to,
              fleet_correlation_id: correlation_id,
              message_context:      message_context,
              provider:             'ollama',
              model:                model,
              request_type:         request_type,
              app_id:               'lex-ollama',
              error:                error,
              worker_node:          node_identity
            ).publish
          rescue StandardError
            nil
          end

          private

          # Build the JSON body for a successful fleet response.
          # The shape varies by request_type but always includes routing, tokens,
          # timestamps, and audit fields required by the wire protocol.
          #
          # @return [Hash] body fields to merge into the LlmResponse options
          def build_response_body(request_type:, body:, usage:, status:, model:,
                                  latency_ms:, received_at:, returned_at:)
            base = {
              routing: {
                provider:   'ollama',
                model:      model,
                tier:       'fleet',
                strategy:   'fleet_dispatch',
                latency_ms: latency_ms
              },
              tokens: {
                input:  usage[:input_tokens]  || 0,
                output: usage[:output_tokens] || 0,
                total:  (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
              },
              stop: { reason: body.is_a?(Hash) ? body['done_reason'] : nil },
              cost: { estimated_usd: 0.0, provider: 'ollama', model: model },
              timestamps: {
                received:       received_at.iso8601(3),
                provider_start: received_at.iso8601(3),
                provider_end:   returned_at.iso8601(3),
                returned:       returned_at.iso8601(3)
              },
              audit: {
                'fleet:execute' => {
                  outcome:     status == 200 ? 'success' : 'error',
                  duration_ms: latency_ms,
                  timestamp:   returned_at.iso8601(3)
                }
              },
              stream: false
            }

            case request_type.to_s
            when 'embed'
              base.merge(
                embeddings: body.is_a?(Hash) ? body['embeddings'] : body
              )
            when 'generate'
              base.merge(
                message: { role: 'assistant', content: body.is_a?(Hash) ? body['response'] : body }
              )
            else
              content = body.is_a?(Hash) ? body.dig('message', 'content') : body
              base.merge(
                message: { role: 'assistant', content: content }
              )
            end
          end

          # Resolve the Ollama host from settings, falling back to the default.
          def ollama_host
            return Helpers::Client::DEFAULT_HOST unless defined?(Legion::Settings)

            Legion::Settings.dig(:ollama, :host) || Helpers::Client::DEFAULT_HOST
          end

          # Resolve the local node identity for worker_node in error messages.
          def node_identity
            return 'unknown' unless defined?(Legion::Settings)

            Legion::Settings.dig(:node, :canonical_name) || 'unknown'
          end

          private_class_method :build_response_body, :ollama_host, :node_identity
        end
      end
    end
  end
end
```

### Method Signatures

| Method | Visibility | Signature | Returns |
|--------|------------|-----------|---------|
| `handle_request` | public | `(model:, request_type: 'chat', reply_to: nil, correlation_id: nil, message_context: {}, **payload)` | `Hash` — `{ result:, status: }` or `{ result: nil, status: 422, error: }` |
| `dispatch` | public | `(model:, request_type:, **payload)` | `Hash` — `{ result: body, status: code }` or `{ result: nil, status: 500, error: msg }` |
| `publish_reply` | public | `(reply_to:, correlation_id:, message_context:, model:, request_type:, result:, received_at:, returned_at:)` | `nil` |
| `publish_error` | public | `(reply_to:, correlation_id:, message_context:, model:, request_type:, error:)` | `nil` |
| `build_response_body` | private | `(request_type:, body:, usage:, status:, model:, latency_ms:, received_at:, returned_at:)` | `Hash` |
| `ollama_host` | private | `()` | `String` |
| `node_identity` | private | `()` | `String` |

### Dispatch Rules (unchanged from current)

| `request_type` | Client method | Payload fields forwarded |
|----------------|---------------|--------------------------|
| `'embed'` | `Client#embed` | `:input` (falls back to `:text`), `:truncate`, `:options`, `:keep_alive`, `:dimensions` |
| `'generate'` | `Client#generate` | `:prompt`, `:images`, `:format`, `:options`, `:system`, `:keep_alive` |
| anything else (including `'chat'`) | `Client#chat` | `:messages`, `:tools`, `:format`, `:options`, `:keep_alive`, `:think` |

### Error Codes Published via `publish_error`

| Scenario | `error.code` | `retriable` | `category` |
|----------|-------------|-------------|------------|
| `stream: true` in request | `unsupported_streaming` | `false` | `validation` |
| `dispatch` raises `StandardError` | `inference_failed` | `true` | `worker` |
| Ollama timeout (Faraday::TimeoutError) | `inference_timeout` | `true` | `worker` |
| Ollama not responding (ConnectionFailed) | `ollama_unavailable` | `true` | `worker` |

Note: In v1, only `unsupported_streaming` produces a proactive `publish_error` call.
The `dispatch` rescue block currently returns `{ status: 500 }` to the actor, which
returns success to the actor ack path. A follow-up (v1.1) should call `publish_error`
from within the rescue block and also forward an error reply to the caller.

### Spec Changes

The existing fleet spec must be updated. Key new examples:

```ruby
describe 'message_context propagation' do
  it 'passes message_context to publish_reply' do
    ctx = { conversation_id: 'conv_123', request_id: 'req_abc' }
    fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                         input: 'hi', reply_to: 'q', correlation_id: 'cid',
                         message_context: ctx)
    expect(described_class).to have_received(:publish_reply)
      .with(hash_including(message_context: ctx))
  end
end

describe 'stream rejection' do
  it 'publishes an error and returns 422 when stream: true' do
    allow(described_class).to receive(:publish_error)
    result = fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                                  messages: [], reply_to: 'q', stream: true)
    expect(result[:status]).to eq(422)
    expect(result[:error]).to eq('unsupported_streaming')
    expect(described_class).to have_received(:publish_error)
      .with(hash_including(error: hash_including(code: 'unsupported_streaming')))
  end

  it 'does not call dispatch when stream: true' do
    allow(described_class).to receive(:publish_error)
    fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                         messages: [], reply_to: 'q', stream: true)
    expect(client_instance).not_to have_received(:chat)
  end
end

describe '#build_response_body' do
  it 'includes routing block with provider, model, tier, strategy, latency_ms' do
    body = fleet.send(:build_response_body,
                      request_type: 'embed', body: { 'embeddings' => [[0.1]] },
                      usage: { input_tokens: 5, output_tokens: 0 },
                      status: 200, model: 'nomic-embed-text',
                      latency_ms: 42,
                      received_at: Time.now.utc, returned_at: Time.now.utc)
    expect(body[:routing][:provider]).to eq('ollama')
    expect(body[:routing][:tier]).to eq('fleet')
    expect(body[:routing][:latency_ms]).to eq(42)
  end

  it 'includes embeddings key for embed request_type' do
    body = fleet.send(:build_response_body,
                      request_type: 'embed', body: { 'embeddings' => [[0.1]] },
                      usage: {}, status: 200, model: 'nomic-embed-text',
                      latency_ms: 10,
                      received_at: Time.now.utc, returned_at: Time.now.utc)
    expect(body[:embeddings]).to eq([[0.1]])
  end

  it 'includes message key for chat request_type' do
    body = fleet.send(:build_response_body,
                      request_type: 'chat',
                      body: { 'message' => { 'content' => 'hello' } },
                      usage: {}, status: 200, model: 'llama3.2',
                      latency_ms: 10,
                      received_at: Time.now.utc, returned_at: Time.now.utc)
    expect(body[:message][:content]).to eq('hello')
    expect(body[:message][:role]).to eq('assistant')
  end
end
```

---

## Step 5: Actor::ModelWorker

**File**: `lib/legion/extensions/ollama/actors/model_worker.rb`

### Current Implementation Summary

- Inherits `Legion::Extensions::Actors::Subscription`
- `use_runner? = false`
- `runner_class` / `runner_function` point to `Runners::Fleet#handle_request`
- `process_message` injects `request_type` and `model` if absent
- `build_and_bind_queue` creates `ModelRequest` and binds it to `LlmRequest` exchange

### Problems

1. **No `prefetch(1)`** — without prefetch, a consumer takes as many messages as the
   broker sends. With 3+ consumers on the same queue, messages do not distribute by
   consumer priority. `prefetch(1)` ensures each consumer finishes before taking the next.
2. **No `consumer_priority`** — `x-priority` is an AMQP consumer argument that tells
   RabbitMQ to prefer this consumer over others when multiple are idle. Without it, all
   consumers have priority 0 (equal delivery, round-robin). The setting
   `legion.ollama.fleet.consumer_priority` must be read and passed in `subscribe`.
3. **`process_message` needs to extract `message_context`** — the current implementation
   injects only `request_type` and `model`. It should also extract `message_context` from
   the raw AMQP delivery and ensure it is present as a symbol key.

### Target Implementation

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Actor
        # Subscription actor that listens on a model-scoped queue and forwards
        # inbound LLM request messages to Runners::Fleet#handle_request.
        #
        # One instance is created per (request_type, model) entry in settings:
        #
        #   legion:
        #     ollama:
        #       fleet:
        #         consumer_priority: 10
        #       subscriptions:
        #         - type: embed
        #           model: nomic-embed-text
        #         - type: chat
        #           model: "qwen3.5:27b"
        #
        # The queue name and routing key both follow the schema:
        #   llm.request.ollama.<type>.<model>
        # where model colons are converted to dots (AMQP topic word separator).
        class ModelWorker < Legion::Extensions::Actors::Subscription
          attr_reader :request_type, :model_name

          def initialize(request_type:, model:, **)
            @request_type = request_type.to_s
            @model_name   = model.to_s
            super(**)
          end

          def runner_class
            Legion::Extensions::Ollama::Runners::Fleet
          end

          def runner_function
            'handle_request'
          end

          # Bypass Legion::Runner — call the runner module directly so we don't
          # need a task record in the database for every LLM inference hop.
          def use_runner?
            false
          end

          # prefetch(1) is required for consumer priority to work correctly:
          # without it, a high-priority consumer can hold multiple messages while
          # lower-priority consumers sit idle. With prefetch=1, each consumer
          # completes one message before RabbitMQ delivers the next, and priority
          # determines which idle consumer gets it.
          def prefetch
            1
          end

          # Consumer priority from settings. Tells RabbitMQ to prefer this consumer
          # over lower-priority ones on the same queue when multiple consumers are idle.
          # Standard scale: GPU server = 10, Mac Studio = 5, developer laptop = 1.
          # Defaults to 0 (equal priority) if not configured.
          def consumer_priority
            return 0 unless defined?(Legion::Settings)

            Legion::Settings.dig(:ollama, :fleet, :consumer_priority) || 0
          end

          # Subscribe options include x-priority argument so RabbitMQ can honour
          # consumer priority when dispatching to competing consumers.
          def subscribe_options
            base = super rescue {}
            base.merge(arguments: { 'x-priority' => consumer_priority })
          end

          # Override queue to return a model-scoped queue bound with the precise
          # routing key for this worker's (type, model) pair.
          def queue
            @queue ||= build_and_bind_queue
          end

          # Enrich every inbound message with the worker's own request_type and model
          # so Runners::Fleet#handle_request always has them, even if the sender omitted
          # them. Also normalises message_context to symbol keys.
          def process_message(payload, metadata, delivery_info)
            msg = super
            msg[:request_type]    ||= @request_type
            msg[:model]           ||= @model_name
            msg[:message_context] ||= {}
            msg
          end

          private

          def build_and_bind_queue
            sanitised_model = @model_name.tr(':', '.')
            routing_key     = "llm.request.ollama.#{@request_type}.#{sanitised_model}"

            queue_obj = Transport::Queues::ModelRequest.new(
              request_type: @request_type,
              model:        @model_name
            )
            exchange_obj = Transport::Exchanges::LlmRequest.new
            queue_obj.bind(exchange_obj, routing_key: routing_key)
            queue_obj
          end
        end
      end
    end
  end
end
```

### Method Signatures

| Method | Visibility | Signature | Returns | Notes |
|--------|------------|-----------|---------|-------|
| `#initialize` | public | `(request_type:, model:, **)` | `ModelWorker` | Sets `@request_type`, `@model_name`, calls `super` |
| `#runner_class` | public | `()` | `Runners::Fleet` | |
| `#runner_function` | public | `()` | `'handle_request'` | |
| `#use_runner?` | public | `()` | `false` | Bypasses task DB |
| `#prefetch` | public | `()` | `1` | Required for consumer priority |
| `#consumer_priority` | public | `()` | `Integer` (0–10) | From `legion.ollama.fleet.consumer_priority` |
| `#subscribe_options` | public | `()` | `Hash` | Merges `arguments: { 'x-priority' => consumer_priority }` into base subscribe opts |
| `#queue` | public | `()` | `Transport::Queues::ModelRequest` | Memoised via `@queue` |
| `#process_message` | public | `(payload, metadata, delivery_info)` | `Hash` | Injects `request_type`, `model`, normalises `message_context` |
| `#build_and_bind_queue` | private | `()` | `Transport::Queues::ModelRequest` | Creates queue, binds to LlmRequest exchange |

### Spec Changes

Add the following examples to the existing `model_worker_spec.rb`:

```ruby
describe '#prefetch' do
  it 'returns 1' do
    worker = worker_class.allocate
    expect(worker.prefetch).to eq(1)
  end
end

describe '#consumer_priority' do
  context 'when Legion::Settings is not defined' do
    it 'returns 0' do
      worker = worker_class.allocate
      expect(worker.consumer_priority).to eq(0)
    end
  end

  context 'when Legion::Settings is defined' do
    before do
      stub_const('Legion::Settings', double('Legion::Settings'))
      allow(Legion::Settings).to receive(:dig)
        .with(:ollama, :fleet, :consumer_priority)
        .and_return(10)
    end

    it 'returns the configured value' do
      worker = worker_class.allocate
      expect(worker.consumer_priority).to eq(10)
    end
  end
end

describe '#process_message' do
  it 'injects message_context as empty hash when absent' do
    worker = worker_class.allocate
    worker.instance_variable_set(:@request_type, 'embed')
    worker.instance_variable_set(:@model_name, 'nomic-embed-text')
    allow_any_instance_of(worker_class.superclass)
      .to receive(:process_message)
      .and_return({ input: 'hello' })

    msg = worker.process_message({ input: 'hello' }, {}, {})
    expect(msg[:message_context]).to eq({})
  end

  it 'does not overwrite an existing message_context' do
    worker = worker_class.allocate
    worker.instance_variable_set(:@request_type, 'embed')
    worker.instance_variable_set(:@model_name, 'nomic-embed-text')
    ctx = { conversation_id: 'conv_123', request_id: 'req_abc' }
    allow_any_instance_of(worker_class.superclass)
      .to receive(:process_message)
      .and_return({ input: 'hello', message_context: ctx })

    msg = worker.process_message({ input: 'hello', message_context: ctx }, {}, {})
    expect(msg[:message_context]).to eq(ctx)
  end
end
```

---

## Configuration Schema

### Full YAML Structure

```yaml
legion:
  ollama:
    host: "http://localhost:11434"    # Ollama API endpoint (default: http://localhost:11434)

    fleet:
      consumer_priority: 10           # Integer 0-10. Standard scale:
                                      #   10 = dedicated GPU server (H100/A100)
                                      #    5 = dedicated CPU server (Mac Studio, M2 Ultra)
                                      #    1 = developer laptop (opportunistic)
                                      #    0 = default (no priority advantage)

    subscriptions:                    # One ModelWorker actor spawned per entry.
      - type: embed                   # "chat", "embed", or "generate"
        model: nomic-embed-text       # Ollama model name. Colons sanitised to dots in
      - type: embed                   #   routing keys/queue names.
        model: mxbai-embed-large
      - type: chat
        model: "qwen3.5:27b"          # Quotes needed in YAML to avoid colon parsing error.
      - type: chat
        model: llama3.2
      - type: generate
        model: llama3.2
```

### Settings Resolution

| Setting path | Type | Default | Purpose |
|---|---|---|---|
| `legion.ollama.host` | String | `'http://localhost:11434'` | Ollama HTTP endpoint |
| `legion.ollama.fleet.consumer_priority` | Integer (0–10) | `0` | AMQP consumer priority |
| `legion.ollama.subscriptions` | Array of `{ type:, model: }` | `[]` | Fleet queue subscriptions |

### Subscription Array Entry Schema

```yaml
type:  String   # Required. One of: chat, embed, generate
model: String   # Required. Ollama model name. Colons are allowed; sanitised internally.
```

Each entry generates:
- One `Actor::ModelWorker` instance
- One `Transport::Queues::ModelRequest` queue declaration
- One binding to `Transport::Exchanges::LlmRequest` with routing key
  `llm.request.ollama.<type>.<sanitised_model>`

### Where Settings Are Read

| Setting | Read in | Method |
|---|---|---|
| `host` | `Runners::Fleet#ollama_host` | `Legion::Settings.dig(:ollama, :host)` |
| `fleet.consumer_priority` | `Actor::ModelWorker#consumer_priority` | `Legion::Settings.dig(:ollama, :fleet, :consumer_priority)` |
| `subscriptions` | Extension boot (in `legion-llm` or `LegionIO`) | Array-iterated to spawn `ModelWorker` actors |

---

## Test Plan

### Files to Create or Update

| Spec file | Status | Action |
|---|---|---|
| `spec/legion/extensions/ollama/transport/exchanges/llm_request_spec.rb` | Exists | Update: add `Fleet::Exchange` ancestor example, remove direct ancestor example |
| `spec/legion/extensions/ollama/transport/queues/model_request_spec.rb` | Exists | Update: rewrite `#queue_options` examples (classic auto-delete, x-max-priority) |
| `spec/legion/extensions/ollama/transport/messages/llm_response_spec.rb` | Exists | Rewrite: change base class assertions, remove old `#message` shape tests, add new examples |
| `spec/legion/extensions/ollama/runners/fleet_spec.rb` | Exists | Update: add message_context, stream rejection, `build_response_body` examples |
| `spec/legion/extensions/ollama/actors/model_worker_spec.rb` | Exists | Update: add prefetch, consumer_priority, message_context injection examples |

### Coverage Targets

#### Transport::Exchanges::LlmRequest (3 examples)
1. Is a subclass of `Legion::LLM::Fleet::Exchange`
2. `#exchange_name` returns `'llm.request'`
3. `#default_type` returns `'topic'`

#### Transport::Queues::ModelRequest (9 examples)
1. Is a subclass of `Legion::Transport::Queue`
2. `#queue_name` for embed model
3. `#queue_name` for chat model
4. `#queue_name` for generate model
5. Model colon sanitisation: `qwen3.5:27b` → `qwen3.5.27b`
6. Model without colons unchanged
7. `#queue_options` — not durable
8. `#queue_options` — auto_delete: true
9. `#queue_options` — `x-max-priority` is 10

#### Transport::Messages::LlmResponse (5 examples)
1. Is a subclass of `Legion::LLM::Fleet::Response`
2. `#app_id` returns `'lex-ollama'`
3. `#type` returns `'llm.fleet.response'`
4. `#routing_key` returns `reply_to` value
5. `#priority` returns `0`

#### Runners::Fleet (20+ examples)
1. embed dispatches to `Client#embed`
2. embed with `:text` fallback when `:input` absent
3. embed returns result with status 200
4. chat dispatches to `Client#chat`
5. chat returns result with status 200
6. generate dispatches to `Client#generate`
7. generate returns result with status 200
8. unknown request_type falls through to chat
9. `reply_to` present → calls `publish_reply`
10. `reply_to` nil → does not call `publish_reply`
11. client raises → returns `{ status: 500, error: msg }`
12. client raises → does not raise to caller
13. `message_context` is passed to `publish_reply`
14. `stream: true` → returns `{ status: 422, error: 'unsupported_streaming' }`
15. `stream: true` → calls `publish_error` with `unsupported_streaming` error
16. `stream: true` → does not call dispatch
17. `build_response_body` — routing block has provider/model/tier/strategy/latency_ms
18. `build_response_body` — embed includes `:embeddings` key
19. `build_response_body` — chat includes `:message` key with role/content
20. `build_response_body` — generate includes `:message` key with response as content
21. `build_response_body` — tokens block has input/output/total
22. `build_response_body` — timestamps block is present and ISO 8601
23. `publish_reply` swallows errors (does not raise)
24. `publish_error` swallows errors (does not raise)

#### Actor::ModelWorker (12+ examples)
1. `runner_class` returns `Runners::Fleet`
2. `runner_function` returns `'handle_request'`
3. `use_runner?` returns false
4. `#prefetch` returns 1
5. `#consumer_priority` returns 0 when Legion::Settings absent
6. `#consumer_priority` returns configured value when Legion::Settings present
7. `#consumer_priority` returns 0 when setting is nil
8. `#process_message` injects `request_type` when absent
9. `#process_message` injects `model` when absent
10. `#process_message` does not override `request_type` when present
11. `#process_message` does not override `model` when present
12. `#process_message` injects `message_context: {}` when absent
13. `#process_message` does not override `message_context` when present
14. routing key for embed model: `llm.request.ollama.embed.nomic-embed-text`
15. routing key colon sanitisation: `qwen3.5:27b` → `qwen3.5.27b`

### Edge Cases

| Scenario | Expected behaviour |
|---|---|
| `message_context` key is string (`'message_context'`) not symbol | `process_message` in base class may or may not symbolise keys — Fleet runner must handle both `payload[:message_context]` and `payload['message_context']`; default to `{}` if both absent |
| `reply_to` is nil | `handle_request` skips both `publish_reply` and `publish_error`; result is still returned to the actor |
| `correlation_id` is nil | `LlmResponse`/`LlmError` published with nil `fleet_correlation_id`; RPC matching on the requester side fails gracefully (no future to fulfill) |
| `dispatch` raises `Faraday::TimeoutError` | Returns `{ status: 500, error: '...' }`, does not crash actor |
| `dispatch` raises `Faraday::ConnectionFailed` | Same as timeout |
| `publish_reply` raises (Legion::Transport unavailable) | Rescued by `rescue StandardError; nil` — actor ack path completes normally |
| `publish_error` raises | Same rescue pattern — actor ack completes |
| Worker receives a message for a model it does not have loaded | Ollama returns HTTP 404, `dispatch` returns `{ status: 404, error: '...' }` — currently no error reply in v1 |
| Consumer priority setting absent from config | `consumer_priority` returns `0`; no AMQP `x-priority` argument pressure |
| `subscribe_options` super raises `NoMethodError` | Guard with `rescue` ensures the merge still works |
| Concurrent requests on same worker | `handle_request` is called synchronously per message (prefetch=1); no concurrent invocations within a single worker |

---

## Standalone Mode

### Guard Mechanism

The fleet transport and actor code is loaded only when the Legion runtime is present:

```ruby
# lib/legion/extensions/ollama.rb
if Legion::Extensions.const_defined?(:Core, false)
  require 'legion/extensions/ollama/transport/exchanges/llm_request'
  require 'legion/extensions/ollama/transport/queues/model_request'
  require 'legion/extensions/ollama/transport/messages/llm_response'
  require 'legion/extensions/ollama/transport'
  require 'legion/extensions/ollama/actors/model_worker'
end
```

The `false` argument to `const_defined?` prevents autoloading — it checks only the
immediately defined constants. This is the correct idiom for checking whether the Legion
runtime is loaded without triggering require chains.

### What Loads in Standalone Mode

```
Always loaded (no guard):
  version.rb
  helpers/client.rb        → Helpers::Client
  helpers/errors.rb        → Helpers::Errors
  helpers/usage.rb         → Helpers::Usage
  runners/completions.rb   → Runners::Completions
  runners/chat.rb          → Runners::Chat
  runners/models.rb        → Runners::Models
  runners/embeddings.rb    → Runners::Embeddings
  runners/blobs.rb         → Runners::Blobs
  runners/s3_models.rb     → Runners::S3Models
  runners/version.rb       → Runners::Version
  runners/fleet.rb         → Runners::Fleet   ← loaded but AMQP methods no-op without Legion::Transport
  client.rb                → Client

Only loaded when Legion::Extensions::Core is present:
  transport/exchanges/llm_request.rb   → Transport::Exchanges::LlmRequest
  transport/queues/model_request.rb    → Transport::Queues::ModelRequest
  transport/messages/llm_response.rb  → Transport::Messages::LlmResponse
  transport.rb                         → Transport (extends Legion::Extensions::Transport)
  actors/model_worker.rb               → Actor::ModelWorker
```

### Why `runners/fleet.rb` is Always Loaded

`Runners::Fleet` contains a guard inside `publish_reply` and `publish_error`:

```ruby
return unless defined?(Legion::Transport)
```

This means the module loads regardless but the AMQP methods are no-ops in standalone mode.
This allows `Client.new.handle_request(...)` to be called in tests or scripts without
Legion runtime, returning the dispatch result without attempting to publish anything.

### Implications for Specs

Specs for `Runners::Fleet` stub `Legion::Transport` as a double:

```ruby
stub_const('Legion::Transport', double('Legion::Transport'))
```

This ensures the `defined?` guard passes and the publish path is exercised in the mock,
without needing a real AMQP connection. Specs for `Transport::Exchanges::LlmRequest`,
`Transport::Queues::ModelRequest`, and `Transport::Messages::LlmResponse` require the
corresponding legion-transport and legion-llm stubs to be present in `spec_helper.rb`.

---

## Files Modified vs. Created

### Modified (all pre-existing)

| File | Change summary |
|---|---|
| `lib/legion/extensions/ollama/transport/exchanges/llm_request.rb` | Inherit `Legion::LLM::Fleet::Exchange` instead of `Legion::Transport::Exchange` |
| `lib/legion/extensions/ollama/transport/queues/model_request.rb` | `queue_options` → classic auto-delete with `x-max-priority: 10` |
| `lib/legion/extensions/ollama/transport/messages/llm_response.rb` | Inherit `Legion::LLM::Fleet::Response`, override `app_id` only |
| `lib/legion/extensions/ollama/runners/fleet.rb` | Add `message_context`, stream rejection, keyword `publish_reply`, `publish_error`, `build_response_body`, settings resolution |
| `lib/legion/extensions/ollama/actors/model_worker.rb` | Add `prefetch`, `consumer_priority`, `subscribe_options`, `message_context` injection in `process_message` |

### Created (none)

All files already exist. No new Ruby source files are needed.

### Spec Files Updated

| Spec file | Change summary |
|---|---|
| `spec/.../transport/exchanges/llm_request_spec.rb` | Update ancestor assertion |
| `spec/.../transport/queues/model_request_spec.rb` | Rewrite `#queue_options` examples |
| `spec/.../transport/messages/llm_response_spec.rb` | Full rewrite |
| `spec/.../runners/fleet_spec.rb` | Add message_context, stream, build_response_body examples |
| `spec/.../actors/model_worker_spec.rb` | Add prefetch, consumer_priority, message_context examples |

---

## Version Bump

After all implementation steps complete, bump `VERSION` from `'0.3.1'` to `'0.3.2'` in
`lib/legion/extensions/ollama/version.rb`.

The changes are functionally significant (new wire protocol compliance, queue type change,
actor subscribe options) and warrant a patch bump. A minor bump (`0.4.0`) would be
appropriate if this is considered a breaking change for nodes currently using the quorum
queue configuration — the queue type change causes RabbitMQ to reject redeclaration with
a precondition error if old (quorum) queues are still present. In practice this is not
breaking because fleet queues are auto-delete and will not persist across a full fleet
restart.

---

## Known Limitations and Deferred Work

### v1 Scope

The following are explicitly out of scope for this implementation and deferred to v2:

| Item | Reason deferred |
|---|---|
| Streaming over fleet bus | Requires new `llm.fleet.chunk` message type, multi-delivery correlation, ReplyDispatcher changes |
| Worker-side metering emission | Metering is emitted by the requesting node after the reply arrives; worker-side metering requires a separate `Metering::Event` publish path in `publish_reply` |
| Error reply on `dispatch` failure | Currently `dispatch` rescue returns `{ status: 500 }` to the actor without calling `publish_error`; the caller times out instead of getting an immediate error |
| Classification enforcement | Workers do not check `classification.level` before executing; restricted requests could be routed to non-compliant workers |
| S3 sync / fleet traffic race | `sync_from_s3` and fleet request arrival can race on a partially-loaded model; workers should drain subscription before syncing |
| JWT auth enforcement | `x-legion-fleet-token` header validation is not implemented in v1; workers accept all requests unconditionally |
| `exchange_id` generation on redelivery | Redelivered messages produce duplicate `exchange_id` in metering/audit; v2 workers should generate new `exchange_id` when `delivery_info[:redelivered]` is true |

### Open Questions from Architecture Doc

These remain open and do not block v1:

- **Q1 (Auth)**: JWT required or optional? v1 defaults to optional.
- **Q3 (Auto-discovery)**: Explicit subscriptions only in v1; auto-detection via `GET /api/tags` deferred.
- **Q8 (S3 sync race)**: No mitigation in v1.
- **Q9 (Classification enforcement)**: No enforcement in v1.

---

**Maintained By**: Matthew Iverson (@Esity)
**Last Updated**: 2026-04-08

# lex-ollama: Ollama Integration for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `../CLAUDE.md`
- **Grandparent**: `../../CLAUDE.md`

## Purpose

Legion Extension that connects LegionIO to Ollama, a local LLM server. Provides text generation,
chat completions, embeddings, model management, blob operations, S3 model distribution, version
reporting, and **fleet queue subscription** for receiving routed LLM requests from the Legion bus.

**GitHub**: https://github.com/LegionIO/lex-ollama
**License**: MIT
**Version**: 0.3.1
**Specs**: 82 examples (12 spec files) — fleet additions add ~35 more

---

## Architecture

```
Legion::Extensions::Ollama
├── Runners/
│   ├── Completions    # generate, generate_stream
│   ├── Chat           # chat, chat_stream
│   ├── Models         # create_model, list_models, show_model, copy_model, delete_model,
│   │                  #   pull_model, push_model, list_running
│   ├── Embeddings     # embed
│   ├── Blobs          # check_blob, push_blob
│   ├── S3Models       # list_s3_models, import_from_s3, sync_from_s3, import_default_models
│   ├── Version        # server_version
│   └── Fleet          # handle_request (fleet dispatcher — chat/embed/generate)
├── Helpers/
│   ├── Client         # Faraday connection to Ollama server (module, factory method)
│   ├── Errors         # error handling + with_retry
│   └── Usage          # usage normalization (maps Ollama token/duration fields to standard shape)
├── Client             # Standalone client class (includes all runners, holds @config)
├── Transport/         # (loaded only when Legion::Extensions::Core is present)
│   ├── Exchanges/
│   │   └── LlmRequest   # topic exchange 'llm.request'
│   ├── Queues/
│   │   └── ModelRequest # parametric queue — one per (type, model) pair
│   └── Messages/
│       └── LlmResponse  # reply message published back to reply_to
└── Actor/
    └── ModelWorker    # subscription actor — one per registered model/type
```

---

## Fleet Queue Subscription

### Overview

When `Legion::Extensions::Core` is available, lex-ollama subscribes to model-scoped queues on the
`llm.request` topic exchange, accepting routed inference work from other Legion fleet members
(lex-llm-gateway, direct publishers, etc.).

### Routing Key Schema

```
llm.request.ollama.<type>.<model>
```

| Segment    | Values                     | Notes                              |
|------------|----------------------------|------------------------------------|
| `ollama`   | literal                    | provider identifier                |
| `type`     | `chat`, `embed`, `generate`| maps to a specific runner method   |
| `model`    | sanitised model name       | `:` replaced with `.` (AMQP rules) |

**Examples:**
```
llm.request.ollama.embed.nomic-embed-text
llm.request.ollama.embed.mxbai-embed-large
llm.request.ollama.chat.qwen3.5.27b          # was qwen3.5:27b
llm.request.ollama.chat.llama3.2
llm.request.ollama.generate.llama3.2
```

### Queue Strategy

Each model+type combination gets its own **durable quorum queue** with a routing key that matches
its queue name exactly. Multiple nodes carrying the same model compete fairly (no SAC) — any
subscriber can serve. The queue name is identical to the routing key for clarity in the management UI.

### Configuration

```yaml
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
```

The extension spawns one `Actor::ModelWorker` per subscription entry at boot.

### Data Flow

```
Publisher (lex-llm-gateway / any fleet node)
  │  routing_key: "llm.request.ollama.embed.nomic-embed-text"
  ▼
Exchange: llm.request  [topic, durable]
  │
  └── Queue: llm.request.ollama.embed.nomic-embed-text  [quorum]
            ▼
       Actor::ModelWorker (type=embed, model=nomic-embed-text)
            ▼
       Runners::Fleet#handle_request
            ▼
       Ollama::Client#embed(model: 'nomic-embed-text', ...)
            ▼
       Transport::Messages::LlmResponse → reply_to queue (if present)
```

### Standalone Mode (no Legion runtime)

All transport/actor requires are guarded behind:
```ruby
if Legion::Extensions.const_defined?(:Core, false)
  # transport + actor requires
end
```
The gem still works as a pure HTTP client library without AMQP, exactly as before.

---

## Key Design Decisions

- `generate_stream` and `chat_stream` yield `{ type: :delta, text: }` and `{ type: :done }` events.
- `S3Models` runner depends on `lex-s3`. Uses SHA256 digest verification. `import_from_s3` writes
  directly to the filesystem; `sync_from_s3` pushes blobs through the Ollama API.
- `S3Models::OLLAMA_REGISTRY_PREFIX = 'manifests/registry.ollama.ai/library'`.
- `Usage` helper normalizes Ollama's token/duration fields to `{ input_tokens:, output_tokens:, ... }`.
- All runners return `{ result: body, status: code }`.
- **`Runners::Fleet` dispatch rules:**
  - `request_type: 'embed'` → `Client#embed`, uses `:input` then falls back to `:text`.
  - `request_type: 'generate'` → `Client#generate`.
  - anything else (including `'chat'` or unknown) → `Client#chat`.
- **`Actor::ModelWorker#use_runner?` is `false`** — bypasses `Legion::Runner` / task DB entirely.
- **Reply publishing** never raises — errors are swallowed so the AMQP ack is not blocked.
- **Colon sanitisation** — `qwen3.5:27b` becomes `qwen3.5.27b` in queue/routing-key strings.

---

## Dependencies

| Gem | Purpose |
|-----|---------|
| `faraday` >= 2.0 | HTTP client for Ollama REST API |
| `lex-s3` >= 0.2 | S3 model distribution operations |

Fleet transport requires Legion runtime gems (`legion-transport`, `LegionIO`) but those are *not*
gemspec dependencies — they are expected to be present in the runtime environment.

---

## Testing

```bash
bundle install
bundle exec rspec        # all examples
bundle exec rubocop
```

---

**Maintained By**: Matthew Iverson (@Esity)
**Last Updated**: 2026-04-07

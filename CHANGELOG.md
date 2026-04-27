# Changelog

## [0.3.5] - 2026-04-25

### Added
- Fleet model workers now bind transient classic queues to shared `llm.fleet` model lanes, with configurable consumer priority, queue expiration, and message TTL.
- Subscription entries can provide a context window so inference workers bind lanes like `llm.fleet.inference.qwen3-5-27b.ctx32768`.

## [0.3.4] - 2026-04-24

### Fixed
- `Ollama.build_actors` and `Ollama.default_settings` were absent from the installed 0.3.3 gem (gem was packaged before `bafb124` landed) — `Actor::ModelWorker` (requires `request_type:` and `model:` kwargs) was reaching the subscription actor pool with no zero-arg initializer, raising `ArgumentError: missing keywords: :request_type, :model` on every boot when running under the Homebrew legionio install

## [0.3.3] - 2026-04-16

### Added
- `Actor::ModelSync` — once actor; runs 5s after extension load; reads `legion.ollama.default_models` and `legion.ollama.s3` from settings; calls `import_from_s3` for any configured model not already present on disk; no-op if either setting is absent

### Fixed
- `Transport::Queues::ModelRequest` deleted — the framework auto-discovers every file in `transport/queues/` and calls `.new` with no arguments at startup, which crashed because `ModelRequest` required `request_type:` and `model:`; the queue definition is now an anonymous class created inline by `Actor::ModelWorker#build_queue_class`
- `Actor::ModelWorker#queue` now returns a CLASS instead of an instance — `Subscription#initialize` calls `queue.new`, so returning an instance caused a silent `NoMethodError` on `NilClass#new`; the anonymous queue class has `queue_name`, `queue_options`, `dlx_enabled`, and `initialize` (exchange bind) defined inline via `define_method`

## [0.3.2] - 2026-04-08

### Changed
- `Transport::Exchanges::LlmRequest` now inherits `Legion::LLM::Fleet::Exchange` instead of declaring exchange properties independently — prevents silent divergence if the canonical exchange definition changes
- `Transport::Queues::ModelRequest` switched from durable quorum queue to classic auto-delete with `x-max-priority: 10` — enables `basic.return` feedback when all workers disconnect; added `dlx_enabled: false` to prevent DLX provisioning on ephemeral queues
- `Transport::Messages::LlmResponse` now inherits `Legion::LLM::Fleet::Response` instead of `Legion::Transport::Message` — gains wire protocol compliance (`type: 'llm.fleet.response'`, `message_context` propagation, default-exchange publishing, `resp_` prefixed message_id); overrides `app_id` to `'lex-ollama'`
- `Runners::Fleet#handle_request` now accepts and propagates `message_context` verbatim from request to response; rejects `stream: true` requests with `unsupported_streaming` error; builds full wire protocol response envelope (routing, tokens, timestamps, audit, cost, stop)
- `Runners::Fleet#publish_reply` switched from positional to keyword arguments; uses `fleet_correlation_id` instead of `correlation_id` to avoid collision with Legion task tracking
- `Runners::Fleet#dispatch` now resolves Ollama host from `Legion::Settings` instead of using hardcoded default
- `Actor::ModelWorker` now sets `prefetch(1)` for fair consumer dispatch; reads `consumer_priority` from `legion.ollama.fleet.consumer_priority` settings; passes `x-priority` in `subscribe_options`; injects `message_context: {}` default in `process_message`

### Added
- `Runners::Fleet#publish_error` — publishes `Legion::LLM::Fleet::Error` to caller's reply_to queue on validation failures (e.g., unsupported streaming)
- `Runners::Fleet#build_response_body` — constructs wire protocol response body with routing, tokens, timestamps, audit, cost, and stop blocks

## [0.3.1] - 2026-04-08

### Added
- `Runners::Fleet` — module-function dispatcher for inbound AMQP LLM request messages; routes by `request_type` to `Client#embed`, `Client#generate`, or `Client#chat`
- `Transport::Exchanges::LlmRequest` — durable topic exchange `llm.request` for fleet routing
- `Transport::Queues::ModelRequest` — parametric durable quorum queue per `(type, model)` pair; sanitises colons in model names to dots
- `Transport::Messages::LlmResponse` — reply message published back to `reply_to` queue after inference
- `Actor::ModelWorker` — subscription actor; one instance per configured `(type, model)` subscription; enriches inbound messages with `request_type` and `model`, bypasses Legion::Runner task DB (`use_runner? false`)
- Fleet queue subscription system: when `Legion::Extensions::Core` is present, subscribes to model-scoped queues on `llm.request` topic exchange using routing key `llm.request.ollama.<type>.<model>`
- Standalone mode: all transport/actor requires guarded behind `const_defined?(:Core, false)` so the gem works as a pure HTTP client library without AMQP

### Fixed
- `Runners::S3Models`: use `::JSON.parse` (stdlib) instead of bare `JSON.parse` which resolves to `Legion::JSON` (symbol keys) inside the `Legion::` namespace — fixes `import_from_s3` and `sync_from_s3` manifest parsing

## [0.3.0] - 2026-04-01

### Added
- S3 model distribution via new `Runners::S3Models` module
- `list_s3_models` to discover models available in an S3 mirror
- `import_from_s3` for direct filesystem model import (works without Ollama running)
- `sync_from_s3` for Ollama API-based model import (push_blob + manifest write)
- `import_default_models` convenience method for fleet provisioning
- Runtime dependency on `lex-s3` for S3 operations
- Streaming S3 downloads via `response_target` to avoid loading multi-GB blobs into memory
- Error propagation in `sync_from_s3` — returns failure with error details when blob push fails
- SHA256 digest verification for all downloaded blobs (import and sync paths)
- Atomic blob writes via temp file + rename (prevents partial/corrupt blobs on failure)
- Cache hits verified by SHA256 digest, not just file size — corrupted local blobs are re-downloaded
- `DigestMismatchError` raised when S3 blob content does not match manifest digest

## [0.2.0] - 2026-03-31

### Added
- `Helpers::Errors` — Faraday exception classification (TimeoutError, ConnectionFailed) with exponential backoff retry (`with_retry`, 3 retries, 0.5s base delay)
- `Helpers::Usage` — standardized usage hash normalization from Ollama response fields (`prompt_eval_count` -> `input_tokens`, `eval_count` -> `output_tokens`, plus duration fields)
- `Helpers::Client#streaming_client` — Faraday connection without JSON response middleware for streaming endpoints
- `Runners::Completions#generate_stream` — streaming generate with per-chunk block callback and full text accumulation
- `Runners::Chat#chat_stream` — streaming chat with per-chunk block callback and full text accumulation

### Changed
- All runner methods wrapped in `Helpers::Errors.with_retry` for production reliability
- `Runners::Completions#generate` now returns a `usage:` key with standardized token/duration counts
- `Runners::Chat#chat` now returns a `usage:` key with standardized token/duration counts
- `Client` class now overrides `streaming_client` for host passthrough

## [0.1.0] - 2026-03-31

### Added
- Initial release
- Completions runner (generate)
- Chat runner (chat with tool and structured output support)
- Models runner (create, list, show, copy, delete, pull, push, running)
- Embeddings runner (embed with single and batch input)
- Blobs runner (check and push binary blobs)
- Version runner (server version)
- Standalone Client class with configurable host
- Faraday-based HTTP client helper with 300s timeout

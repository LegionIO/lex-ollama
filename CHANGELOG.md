# Changelog

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

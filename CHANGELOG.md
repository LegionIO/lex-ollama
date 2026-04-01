# Changelog

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

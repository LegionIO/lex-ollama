# Changelog

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

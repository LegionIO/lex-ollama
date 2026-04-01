# S3 Model Distribution for lex-ollama

## Problem

Thousands of engineers pulling models from the public Ollama registry is wasteful and unreliable. Models should be cached in internal S3 and distributed from there. Fleet-wide model updates should be broadcast via RabbitMQ.

## Design

### New Runner: `Runners::S3Models`

A new runner module alongside the existing `Models` runner. Three primary methods plus one convenience method.

#### `import_from_s3` (filesystem write)

Downloads manifest + blobs from S3, writes directly to `~/.ollama/models/`.

```ruby
import_from_s3(
  model:,                    # e.g. "llama3:latest"
  bucket:,                   # S3 bucket name
  prefix: "ollama/models",   # S3 key prefix
  models_path: nil,          # local Ollama models dir, defaults to ~/.ollama/models
  **s3_opts                  # passed through to lex-s3 (endpoint:, region:, access_key_id:, etc.)
)
```

Flow:
1. Parse `model` into `name` + `tag` (default tag: `latest`)
2. Download manifest from S3: `{prefix}/manifests/registry.ollama.ai/library/{name}/{tag}`
3. Parse manifest JSON to get the list of blob digests
4. For each blob, check if it already exists locally with matching SHA256 digest (skip if valid)
5. Stream blob from S3 to `.tmp` file, verify SHA256, atomic rename to final path
6. Raise `DigestMismatchError` if any blob fails verification (temp file cleaned up)
7. Write the manifest file
8. Return `{ result: true, model:, blobs_downloaded:, blobs_skipped:, status: 200 }`

Best for: provisioning, bootstrapping, when Ollama is not yet running.

#### `sync_from_s3` (Ollama API + filesystem manifest)

Downloads from S3, pushes blobs through Ollama's API, writes manifest to filesystem.

```ruby
sync_from_s3(
  model:,
  bucket:,
  prefix: "ollama/models",
  host: nil,                   # Ollama server host
  models_path: nil,            # local models dir for manifest write
  **s3_opts                    # passed to lex-s3
)
```

Flow:
1. Parse model, download manifest from S3
2. For each blob digest, `check_blob` via Ollama API -- skip if already present
3. Stream blob from S3 to tempfile, verify SHA256 digest
4. `push_blob` to Ollama API, check return value for success
5. If any blob fails: return `{ result: false, errors: [...], status: 500 }`
6. Write manifest to `{models_path}/manifests/registry.ollama.ai/library/{name}/{tag}`
7. Return `{ result: true, model:, blobs_pushed:, blobs_skipped:, status: 200 }`

Best for: when Ollama is running and you want blob validation through the API.

#### `list_s3_models`

Lists available models in the S3 mirror.

```ruby
list_s3_models(
  bucket:,
  prefix: "ollama/models",
  **s3_opts
)
```

Lists manifest keys under the prefix and parses them into model name/tag pairs.

#### `import_default_models`

Convenience method that reads `default_models` from settings and calls `import_from_s3` for each.

### Settings

```yaml
legion:
  ollama:
    s3:
      bucket: "legion"
      prefix: "ollama/models"
      endpoint: "https://mesh.s3api-core.optum.com"
      region: "us-east-2"
    default_models:
      - "llama3:latest"
      - "nomic-embed-text:latest"
    models_path: null  # defaults to ~/.ollama/models, respects OLLAMA_MODELS env var
```

### Dependency

`lex-ollama.gemspec` adds a runtime dependency on `lex-s3` (`>= 0.1`). The `S3Models` runner uses `Legion::Extensions::S3::Client` for all S3 operations.

### Data Flow

```
S3 (mesh.s3api-core.optum.com)
  |
  | HTTPS (direct, no AMQP)
  v
Node: S3Models runner
  |
  |-- import_from_s3 --> filesystem write to ~/.ollama/models/
  |-- sync_from_s3   --> Ollama HTTP API (push_blob + create_model)
```

Fleet broadcast: publish a message to the `ollama.s3_models` queue (natural LEX runner behavior). Each node picks it up and runs the download independently from S3.

### File Layout

```
lib/legion/extensions/ollama/
  runners/
    models.rb          # existing, unchanged
    s3_models.rb       # NEW
  client.rb            # updated to include Runners::S3Models

spec/legion/extensions/ollama/runners/
  s3_models_spec.rb    # NEW
```

No changes to existing runner methods or the Helpers::Client module.

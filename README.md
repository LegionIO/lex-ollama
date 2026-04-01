# lex-ollama

Ollama integration for [LegionIO](https://github.com/LegionIO/LegionIO). Connects LegionIO to a local Ollama LLM server for text generation, chat completions, embeddings, and model management.

## Installation

```bash
gem install lex-ollama
```

## Functions

### Completions
- `generate` - Generate a text completion (POST /api/generate)
- `generate_stream` - Stream a text completion with per-chunk callbacks

### Chat
- `chat` - Generate a chat completion with message history and tool support (POST /api/chat)
- `chat_stream` - Stream a chat completion with per-chunk callbacks

### Models
- `create_model` - Create a model from another model, GGUF, or safetensors (POST /api/create)
- `list_models` - List locally available models (GET /api/tags)
- `show_model` - Show model details, template, parameters, license (POST /api/show)
- `copy_model` - Copy a model to a new name (POST /api/copy)
- `delete_model` - Delete a model and its data (DELETE /api/delete)
- `pull_model` - Download a model from the Ollama library (POST /api/pull)
- `push_model` - Upload a model to the Ollama library (POST /api/push)
- `list_running` - List models currently loaded in memory (GET /api/ps)

### Embeddings
- `embed` - Generate embeddings from a model (POST /api/embed)

### Blobs
- `check_blob` - Check if a blob exists on the server (HEAD /api/blobs/:digest)
- `push_blob` - Upload a binary blob to the server (POST /api/blobs/:digest)

### S3 Model Distribution
- `list_s3_models` - List models available in an S3 mirror
- `import_from_s3` - Download model from S3 directly to Ollama's filesystem (works before Ollama starts)
- `sync_from_s3` - Download model from S3, push blobs through Ollama's API, write manifest to filesystem
- `import_default_models` - Import a list of models from S3 (fleet provisioning)

### Version
- `server_version` - Retrieve the Ollama server version (GET /api/version)

## Standalone Client

```ruby
client = Legion::Extensions::Ollama::Client.new
# or with custom host
client = Legion::Extensions::Ollama::Client.new(host: 'http://remote:11434')

# Chat
result = client.chat(model: 'llama3.2', messages: [{ role: 'user', content: 'Hello!' }])

# Generate
result = client.generate(model: 'llama3.2', prompt: 'Why is the sky blue?')

# Embeddings
result = client.embed(model: 'all-minilm', input: 'Some text to embed')

# List models
result = client.list_models

# Streaming generate
client.generate_stream(model: 'llama3.2', prompt: 'Tell me a story') do |event|
  case event[:type]
  when :delta then print event[:text]
  when :done  then puts "\nDone!"
  end
end

# Streaming chat
client.chat_stream(model: 'llama3.2', messages: [{ role: 'user', content: 'Hello!' }]) do |event|
  print event[:text] if event[:type] == :delta
end
```

## S3 Model Distribution

Pull models from an internal S3 mirror instead of the public Ollama registry:

```ruby
client = Legion::Extensions::Ollama::Client.new

# List available models in S3
client.list_s3_models(bucket: 'legion', endpoint: 'https://mesh.s3api-core.optum.com')

# Import directly to filesystem (works without Ollama running)
client.import_from_s3(model: 'llama3:latest', bucket: 'legion',
                      endpoint: 'https://mesh.s3api-core.optum.com')

# Push through Ollama API (requires Ollama running)
client.sync_from_s3(model: 'llama3:latest', bucket: 'legion',
                    endpoint: 'https://mesh.s3api-core.optum.com')

# Provision fleet with default models
client.import_default_models(
  default_models: %w[llama3:latest nomic-embed-text:latest],
  bucket: 'legion',
  endpoint: 'https://mesh.s3api-core.optum.com'
)
```

S3 operations use [lex-s3](https://github.com/LegionIO/lex-s3). The S3 bucket should mirror the Ollama models directory structure (`manifests/` and `blobs/` under the configured prefix).

All API calls include automatic retry with exponential backoff on connection failures and timeouts.

Generate and chat responses include standardized `usage:` data:
```ruby
result = client.generate(model: 'llama3.2', prompt: 'Hello')
result[:usage]  # => { input_tokens: 1, output_tokens: 5, total_duration: ..., ... }
```

## Requirements

- Ruby >= 3.4
- [LegionIO](https://github.com/LegionIO/LegionIO) framework
- [Ollama](https://ollama.com) running locally or on a remote host

## License

MIT

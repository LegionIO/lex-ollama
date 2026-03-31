# lex-ollama

Ollama integration for [LegionIO](https://github.com/LegionIO/LegionIO). Connects LegionIO to a local Ollama LLM server for text generation, chat completions, embeddings, and model management.

## Installation

```bash
gem install lex-ollama
```

## Functions

### Completions
- `generate` - Generate a text completion (POST /api/generate)

### Chat
- `chat` - Generate a chat completion with message history and tool support (POST /api/chat)

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
```

## Requirements

- Ruby >= 3.4
- [LegionIO](https://github.com/LegionIO/LegionIO) framework
- [Ollama](https://ollama.com) running locally or on a remote host

## License

MIT

# lex-ollama: Ollama Integration for LegionIO

**Parent**: `/Users/miverso2/rubymine/legion/extensions-ai/CLAUDE.md`

## Purpose

Legion Extension that connects LegionIO to Ollama, a local LLM server. Provides text generation, chat completions, embeddings, model management, and blob operations.

**GitHub**: https://github.com/LegionIO/lex-ollama
**License**: MIT

## Architecture

```
Legion::Extensions::Ollama
├── Runners/
│   ├── Completions        # POST /api/generate
│   ├── Chat               # POST /api/chat
│   ├── Models             # CRUD + pull/push/running
│   ├── Embeddings         # POST /api/embed
│   ├── Blobs              # HEAD/POST /api/blobs/:digest
│   └── Version            # GET /api/version
├── Helpers/
│   └── Client             # Faraday connection to Ollama server
└── Client                 # Standalone client class
```

## Dependencies

| Gem | Purpose |
|-----|---------|
| faraday | HTTP client for Ollama REST API |

## Testing

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

---

**Maintained By**: Matthew Iverson (@Esity)

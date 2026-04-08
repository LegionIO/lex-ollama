# Fleet Architecture Diagrams

## 1. Current State: How Fleet Works Today

Everything flows through lex-llm-gateway's single `InferenceWorker`.

```
                         REQUESTING NODE                                          GPU WORKER NODE
                    (laptop / edge service)                                   (Mac Studio / A100)

               +---------------------------+                           +---------------------------+
               |      Any Legion Code      |                           |    lex-llm-gateway        |
               |                           |                           |                           |
               |  Legion::LLM.chat(        |                           |  InferenceWorker actor    |
               |    model: 'llama3.2',     |                           |    consumes from queue    |
               |    tier: :fleet           |                           |           |               |
               |  )                        |                           |           v               |
               |        |                  |                           |  FleetHandler runner      |
               |        v                  |                           |    validates JWT          |
               |  lex-llm-gateway          |                           |           |               |
               |  Runners::Inference       |                           |           v               |
               |        |                  |                           |  Legion::LLM.chat(...)    |
               |        v                  |                           |    (calls local Ollama)   |
               |  Runners::Fleet           |                           |           |               |
               |    signs JWT              |                           |           v               |
               |    generates corr_id      |                           |  publish reply to         |
               |    publishes request      |                           |  reply_to queue           |
               |    waits on future (30s)  |                           +---------------------------+
               +---------------------------+                                       |
                         |                                                         |
                         v                                                         v
          +---------------------------------------------------------------------------+
          |                         RabbitMQ                                           |
          |                                                                           |
          |   Exchange: llm.inference (direct)                                        |
          |        |                                                                  |
          |        |  routing_key: 'inference.request'                                |
          |        v                                                                  |
          |   Queue: llm.inference.process (durable)                                  |
          |        consumed by InferenceWorker ^                                      |
          |                                                                           |
          |   Reply: default exchange                                                 |
          |        routing_key: 'llm.fleet.reply.<hex>'  (auto-delete queue)          |
          |        consumed by ReplyDispatcher on requesting node ^                   |
          |                                                                           |
          |   Exchange: llm.metering (topic)                                          |
          |        |                                                                  |
          |        v                                                                  |
          |   Queue: llm.metering.write (durable)                                     |
          |        consumed by MeteringWriter on DB node                              |
          +---------------------------------------------------------------------------+
```

**Problems with this:**
- Single queue `llm.inference.process` for ALL models, ALL providers, ALL request types
- No way to route `embed` requests to embedding-optimized nodes
- No way to route a specific model to nodes that have it loaded
- FleetHandler calls `Legion::LLM` which adds indirection (settings lookup, provider resolution)
- Every GPU node must run lex-llm-gateway + full Legion runtime


## 2. Proposed State: Provider Extensions Subscribe Directly

lex-ollama (and future provider extensions) subscribe to model-specific queues.

```
                         REQUESTING NODE                                    GPU WORKER NODE(S)
                    (laptop / edge service)                              (Mac Studio / A100 / etc)

               +---------------------------+                        +-------------------------------+
               |      Any Legion Code      |                        |         lex-ollama            |
               |                           |                        |                               |
               |  Legion::LLM.chat(        |                        |  ModelWorker actor (chat,     |
               |    model: 'qwen3.5:27b',  |                        |    qwen3.5:27b)               |
               |    tier: :fleet           |                        |         |                     |
               |  )                        |                        |         v                     |
               |        |                  |                        |  Runners::Fleet               |
               |        v                  |                        |    #handle_request            |
               |  lex-llm-gateway          |                        |         |                     |
               |  Runners::Fleet           |                        |         v                     |
               |    signs JWT              |                        |  Ollama::Client.chat(         |
               |    generates corr_id      |                        |    model: 'qwen3.5:27b')     |
               |    builds routing key:    |                        |    (direct HTTP to Ollama)    |
               |      llm.request.ollama   |                        |         |                     |
               |        .chat.qwen3.5.27b  |                        |         v                     |
               |    publishes request      |                        |  publish reply to             |
               |    waits on future (30s)  |                        |  reply_to queue               |
               |        |                  |                        +-------------------------------+
               |        v                  |
               |  Runners::Metering        |                        +-------------------------------+
               |    publish metering event |                        |         lex-ollama            |
               +---------------------------+                        |                               |
                         |                                          |  ModelWorker actor (embed,    |
                         |                                          |    nomic-embed-text)          |
                         v                                          |         |                     |
          +------------------------------------------+              |         v                     |
          |              RabbitMQ                     |              |  Ollama::Client.embed(        |
          |                                          |              |    model: 'nomic-embed-text') |
          |  Exchange: llm.request (topic, durable)  |              +-------------------------------+
          |       |                                  |
          |       |  llm.request.ollama.chat         |              +-------------------------------+
          |       |    .qwen3.5.27b                  |              |    (future) lex-openai        |
          |       |                                  |              |                               |
          |       +---> Queue: llm.request.ollama    |              |  ModelWorker actor (chat,     |
          |       |       .chat.qwen3.5.27b [quorum] | ----------> |    gpt-4o)                    |
          |       |                                  |              +-------------------------------+
          |       |  llm.request.ollama.embed
          |       |    .nomic-embed-text              |
          |       |                                  |
          |       +---> Queue: llm.request.ollama    |
          |       |       .embed.nomic-embed-text    | ---------->  (consumed by lex-ollama above)
          |       |                                  |
          |       |  llm.request.openai.chat.gpt-4o  |
          |       |                                  |
          |       +---> Queue: llm.request.openai    |
          |               .chat.gpt-4o              | ---------->  (consumed by lex-openai above)
          |                                          |
          |  Reply: default exchange                 |
          |    routing_key: llm.fleet.reply.<hex>    |
          |                                          |
          |  Exchange: llm.metering (topic)          |
          |    (unchanged from current)              |
          +------------------------------------------+
```


## 3. What Stays vs What Changes in lex-llm-gateway

```
  lex-llm-gateway responsibilities
  ================================

  KEEPS (requester side + infrastructure)        LOSES (worker side)
  +-----------------------------------------+    +----------------------------------+
  | Runners::Fleet (requester/dispatcher)    |    | InferenceWorker actor            |
  |   - JWT signing                         |    |   replaced by lex-ollama         |
  |   - correlation ID generation           |    |   ModelWorker (per model)        |
  |   - ReplyDispatcher (future matching)   |    |                                  |
  |   - timeout handling                    |    | FleetHandler runner              |
  |                                         |    |   replaced by lex-ollama         |
  | Runners::Metering                       |    |   Runners::Fleet#handle_request  |
  |   - event construction                  |    +----------------------------------+
  |   - publish-or-spool                    |
  |   - SpoolFlush actor (60s drain)        |         CHANGES
  |                                         |    +----------------------------------+
  | Runners::MeteringWriter                 |    | Fleet.dispatch now publishes to  |
  |   - DB persistence on metering nodes    |    |   llm.request (topic) instead   |
  |   - cost estimation                     |    |   of llm.inference (direct)     |
  |                                         |    |                                  |
  | Runners::UsageReporter                  |    | routing_key changes from         |
  |   - budget_check, summary, top N        |    |   'inference.request'            |
  |                                         |    |   to                             |
  | Runners::ProviderStats                  |    |   'llm.request.<provider>        |
  |   - circuit breaker observability       |    |    .<type>.<model>'              |
  | Helpers::Auth (JWT)                     |    +----------------------------------+
  +-----------------------------------------+
```


## 4. Message Flow: A Single Fleet Chat Request

Step-by-step lifecycle of `Legion::LLM.chat(model: 'qwen3.5:27b', tier: :fleet)`:

```
  Requesting Node                    RabbitMQ                         GPU Worker Node
  ---------------                    --------                         ---------------

  1. Legion::LLM.chat()
       |
       v
  2. Router resolves:
     tier=fleet,
     provider=ollama,
     model=qwen3.5:27b
       |
       v
  3. Gateway Fleet.dispatch()
     - sign JWT
     - corr_id = uuid
     - routing_key =
       "llm.request.ollama
        .chat.qwen3.5.27b"
     - reply_to =
       "llm.fleet.reply.<hex>"
       |
       v
  4. Publish to --------->  5. Exchange: llm.request
     llm.request exchange       (topic, durable)
       |                              |
       |                              | matches routing key
       |                              v
       |                    6. Queue: llm.request
       |                       .ollama.chat
       |                       .qwen3.5.27b
       |                              |
       |                              +----------->  7. ModelWorker actor
       |                                                receives message
       |                                                    |
       |                                                    v
       |                                             8. Fleet#handle_request
       |                                                - validate JWT (optional)
       |                                                - type='chat'
       |                                                    |
       |                                                    v
       |                                             9. Ollama::Client.chat(
       |                                                  model: 'qwen3.5:27b',
       |                                                  messages: [...])
       |                                                    |
       |                                                    v
       |                                            10. Ollama HTTP API
       |                                                localhost:11434/api/chat
       |                                                    |
       |                                                    v
       |                                            11. Build response:
       |                                                { correlation_id,
       |                                                  response, tokens }
       |                                                    |
       |                    12. default exchange  <---------+
       |                        routing_key:
       |                        "llm.fleet.reply.<hex>"
       |                              |
       v                              v
 13. ReplyDispatcher    <---  14. Reply queue
     matches corr_id              (auto-delete)
       |
       v
 15. Future resolved,
     response returned
       |
       v
 16. Metering.publish_or_spool()
     -> llm.metering exchange
```


## 5. Queue Topology: Multiple Nodes, Same Model

When two Mac Studios both serve `llama3.2` chat, they compete on the same queue:

```
                                    llm.request (topic exchange)
                                              |
                          llm.request.ollama.chat.llama3.2
                                              |
                                              v
                              +-------------------------------+
                              |  Queue: llm.request.ollama    |
                              |    .chat.llama3.2             |
                              |  (quorum, durable)            |
                              +-------------------------------+
                                    /                 \
                                   /   round-robin     \
                                  /    (fair dispatch)   \
                                 v                        v
                    +------------------+      +------------------+
                    |  Mac Studio #1   |      |  Mac Studio #2   |
                    |  lex-ollama      |      |  lex-ollama      |
                    |  ModelWorker     |      |  ModelWorker     |
                    |  (chat,llama3.2) |      |  (chat,llama3.2) |
                    +------------------+      +------------------+
                           |                         |
                           v                         v
                    Ollama :11434              Ollama :11434
                    (local instance)          (local instance)


  When one node also serves embeddings, it runs additional ModelWorkers:

                    +------------------+
                    |  Mac Studio #1   |
                    |                  |
                    |  ModelWorker     |  <-- llm.request.ollama.chat.llama3.2
                    |  ModelWorker     |  <-- llm.request.ollama.embed.nomic-embed-text
                    |  ModelWorker     |  <-- llm.request.ollama.chat.qwen3.5.27b
                    +------------------+
```


## 6. End-to-End: Agent Requests GPU Inference

A Legion agent (e.g., a GAIA cognitive phase running on a developer laptop) needs to embed
a document using `nomic-embed-text` on a remote Mac Studio with a GPU. This traces every
hop, process boundary, and wire protocol from the agent's Ruby call to the embedding vector
arriving back in the agent's memory.

```
  AGENT NODE (developer laptop, no GPU)
  ======================================

  lex-synapse (cognitive extension)
    |
    |  Phase: Consolidation needs to embed a memory chunk
    |  Calls Legion::LLM.embed(text: "...", model: 'nomic-embed-text')
    |
    v
  legion-llm  Router
    |
    |  1. Intent resolution:
    |     - request_type = 'embed'
    |     - model = 'nomic-embed-text'
    |
    |  2. Tier resolution:
    |     - :local — is Ollama running locally?
    |       NO (laptop has no GPU, Ollama not installed)
    |     - :fleet — is Legion::Transport connected?
    |       YES (RabbitMQ connection alive)
    |       -> tier = :fleet
    |     - :cloud — not reached (fleet available)
    |
    |  3. Provider resolution:
    |     - model 'nomic-embed-text' -> provider = 'ollama'
    |
    v
  lex-llm-gateway  Runners::Fleet.dispatch()
    |
    |  4. Build request envelope:
    |     {
    |       model:          'nomic-embed-text',
    |       request_type:   'embed',
    |       text:           '...',              # embed payload
    |       messages:       nil,                # not a chat request
    |       reply_to:       'llm.fleet.reply.a3f8c1',  # this node's reply queue
    |       correlation_id: 'fleet_b7e2d4...',
    |       signed_token:   '<JWT, 60s TTL>'    # (if auth enabled)
    |     }
    |
    |  5. Build routing key:
    |     provider = 'ollama', type = 'embed', model = 'nomic-embed-text'
    |     -> "llm.request.ollama.embed.nomic-embed-text"
    |
    |  6. Register correlation_id in ReplyDispatcher:
    |     Concurrent::Map: 'fleet_b7e2d4...' -> ResolvableFuture
    |
    |  7. Ensure reply consumer is running:
    |     ReplyDispatcher.ensure_consumer()
    |     -> Bunny consumer on queue 'llm.fleet.reply.a3f8c1' (auto-delete)
    |     -> on_delivery: match correlation_id, fulfill future
    |
    v
  AMQP publish  =============================================================>
    |                                                                          |
    |  Wire: AMQP 0.9.1 basic.publish                                         |
    |    exchange:    'llm.request'                                            |
    |    routing_key: 'llm.request.ollama.embed.nomic-embed-text'              |
    |    properties:                                                           |
    |      content_type:  'application/json'                                   |
    |      reply_to:      'llm.fleet.reply.a3f8c1'                             |
    |      correlation_id: 'fleet_b7e2d4...'                                   |
    |    body: JSON envelope from step 4                                       |
    |                                                                          v
    |
    |                          RABBITMQ BROKER
    |                          ================
    |
    |                          Exchange: llm.request
    |                            type: topic, durable: true
    |                                    |
    |                                    | routing_key match:
    |                                    | 'llm.request.ollama.embed.nomic-embed-text'
    |                                    |   matches binding on queue with same name
    |                                    |
    |                                    v
    |                          Queue: llm.request.ollama.embed.nomic-embed-text
    |                            type: quorum, durable: true
    |                            consumers: 2 (Mac Studio #1 and #2)
    |                                    |
    |                                    | round-robin dispatch
    |                                    | (prefetch=1, fair)
    |                                    |
    |                                    +----> delivered to Mac Studio #1
    |                                           (won the round-robin)
    |
    |
    |  GPU WORKER NODE (Mac Studio #1, M2 Ultra, 192GB)
    |  ==================================================
    |                                                                          |
    |                          lex-ollama  Actor::ModelWorker                   |
    |                            (subscription: embed, nomic-embed-text)        |
    |                                    |                                     |
    |                                    v                                     |
    |                           8. AMQP basic.deliver                          |
    |                              decode JSON payload                         |
    |                                    |                                     |
    |                                    v                                     |
    |                           9. Runners::Fleet#handle_request               |
    |                              - validate JWT (if auth enabled)            |
    |                              - extract: request_type='embed',            |
    |                                model='nomic-embed-text',                 |
    |                                text='...'                                |
    |                                    |                                     |
    |                                    v                                     |
    |                          10. Dispatch by request_type:                   |
    |                              'embed' -> Ollama::Client#embed             |
    |                                    |                                     |
    |                                    v                                     |
    |                          11. Faraday HTTP request                        |
    |                              POST http://localhost:11434/api/embed       |
    |                              {                                           |
    |                                "model": "nomic-embed-text",              |
    |                                "input": "..."                            |
    |                              }                                           |
    |                                    |                                     |
    |                                    v                                     |
    |                          12. Ollama process (local)                      |
    |                              - model already loaded in VRAM              |
    |                              - runs embedding inference on GPU           |
    |                              - returns 768-dim float vector              |
    |                                    |                                     |
    |                                    v                                     |
    |                          13. HTTP 200 response:                          |
    |                              {                                           |
    |                                "embeddings": [[0.012, -0.437, ...]],     |
    |                                "total_duration": 42000000,               |
    |                                "load_duration": 0,                       |
    |                                "prompt_eval_count": 128                  |
    |                              }                                           |
    |                                    |                                     |
    |                                    v                                     |
    |                          14. Build reply envelope:                       |
    |                              {                                           |
    |                                correlation_id: 'fleet_b7e2d4...',        |
    |                                response: { embeddings: [[...]] },        |
    |                                input_tokens: 128,                        |
    |                                output_tokens: 0,                         |
    |                                provider: 'ollama',                       |
    |                                model_id: 'nomic-embed-text'              |
    |                              }                                           |
    |                                    |                                     |
    |                                    v                                     |
    |                          15. AMQP publish reply:                         |
    |                              exchange: '' (default)                      |
    |                              routing_key: 'llm.fleet.reply.a3f8c1'       |
    |                              correlation_id: 'fleet_b7e2d4...'           |
    |                              body: JSON from step 14                     |
    |                                    |                                     |
    |                                    v                                     |
    |                          16. AMQP basic.ack                              |
    |                              (message acknowledged, removed from queue)  |
    |                                                                          |
    |                                                                          |
    |  <===================================================================== |
    |                          RABBITMQ BROKER
    |                          ================
    |
    |                          default exchange
    |                            routing_key: 'llm.fleet.reply.a3f8c1'
    |                                    |
    |                                    v
    |                          Queue: llm.fleet.reply.a3f8c1
    |                            type: classic, auto-delete: true
    |                            consumers: 1 (agent node's ReplyDispatcher)
    |
    v
  AGENT NODE (continued)
  ======================

  lex-llm-gateway  ReplyDispatcher
    |
    |  17. on_delivery callback fires:
    |      - decode JSON
    |      - lookup correlation_id 'fleet_b7e2d4...' in Concurrent::Map
    |      - fulfill future with response hash
    |      - delete from map
    |
    v
  lex-llm-gateway  Runners::Fleet.dispatch() (resumed)
    |
    |  18. future.value!(30) returns:
    |      { correlation_id: '...', response: { embeddings: [[...]] }, ... }
    |
    |  19. Deregister correlation_id from ReplyDispatcher (ensure block)
    |
    v
  lex-llm-gateway  Runners::Inference (if called through gateway)
    |
    |  20. Metering.publish_or_spool():
    |      {
    |        node_id:        'laptop-a3f8',
    |        worker_id:      'mac-studio-1',
    |        request_type:   'embed',
    |        tier:           'fleet',
    |        provider:       'ollama',
    |        model_id:       'nomic-embed-text',
    |        input_tokens:   128,
    |        output_tokens:  0,
    |        latency_ms:     42,
    |        recorded_at:    '2026-04-08T14:30:00Z'
    |      }
    |      -> published to llm.metering exchange
    |         routing_key: 'metering.embed'
    |
    v
  legion-llm  Router (returned)
    |
    |  21. Unwrap response, return embeddings to caller
    |
    v
  lex-synapse  (original caller)
    |
    |  22. Receives: [[0.012, -0.437, ...]]
    |      Stores embedding in Apollo vector store
    |      Consolidation phase continues
    |
    +--- done (total wall clock: ~80ms network + 42ms inference = ~122ms)


  Meanwhile, asynchronously:

  DB NODE
  =======

  lex-llm-gateway  MeteringWriter actor
    |
    |  23. Consumes metering event from llm.metering.write queue
    |      - estimates cost_usd (local model = $0.00)
    |      - INSERT INTO metering_records (...)
    |
    +--- metering persisted
```

**Key observations:**
- The agent code (`lex-synapse`) has no idea it went to a remote GPU. It called `Legion::LLM.embed()` and got a vector back.
- Five process boundaries are crossed: Agent -> RabbitMQ -> GPU Worker -> Ollama -> back through RabbitMQ -> Agent.
- The reply path uses AMQP's default exchange (direct routing by queue name), not the `llm.request` topic exchange.
- Metering happens on the requesting node after the response arrives, not on the GPU worker.
- The GPU worker only needs `lex-ollama` + `legion-transport`. No `legion-llm`, no `legion-data`, no DB.


## 7. Same Flow, Every Scenario: What Actually Changes

The end-to-end flow in diagram 6 is **identical** regardless of hardware or request type.
Only four values change — everything else (steps 1-23, process boundaries, AMQP hops,
reply correlation, metering) stays exactly the same.

```
  +-----------------------------------------------------------------------------------+
  |                     WHAT CHANGES BETWEEN SCENARIOS                                 |
  +-----------------------------------------------------------------------------------+
  |                                                                                   |
  |  Only these four values are different:                                             |
  |                                                                                   |
  |    1. Routing key         llm.request.ollama.<TYPE>.<MODEL>                       |
  |    2. Queue name          (same as routing key)                                   |
  |    3. Runner method       Client#<chat | embed | generate>                        |
  |    4. Ollama HTTP path    /api/<chat | embed | generate>                          |
  |                                                                                   |
  |  Everything else is identical: JWT, correlation_id, ReplyDispatcher,              |
  |  reply_to queue, metering event, DB persistence.                                  |
  +-----------------------------------------------------------------------------------+


  SCENARIO A: Mac Studio — embed (nomic-embed-text)
  ==================================================

    Routing key:    llm.request.ollama.embed.nomic-embed-text
    Queue:          llm.request.ollama.embed.nomic-embed-text  [quorum]
    Runner:         Ollama::Client#embed(model: 'nomic-embed-text', input: '...')
    Ollama HTTP:    POST /api/embed  { "model": "nomic-embed-text", "input": "..." }
    Response:       { "embeddings": [[0.012, -0.437, ...]], "prompt_eval_count": 128 }
    Typical time:   ~40ms inference, ~120ms total

    Hardware path:
    +-------------------+     localhost:11434      +-------------------+
    | Mac Studio        | ----------------------> | Ollama            |
    | M2 Ultra, 192GB   |     POST /api/embed     | nomic-embed-text  |
    | unified memory    | <---------------------- | loaded in unified |
    | lex-ollama        |     200 OK + vector     | memory (768MB)    |
    +-------------------+                         +-------------------+


  SCENARIO B: Mac Studio — chat (qwen3.5:27b)
  =============================================

    Routing key:    llm.request.ollama.chat.qwen3.5.27b
    Queue:          llm.request.ollama.chat.qwen3.5.27b  [quorum]
    Runner:         Ollama::Client#chat(model: 'qwen3.5:27b', messages: [...])
    Ollama HTTP:    POST /api/chat  { "model": "qwen3.5:27b", "messages": [...] }
    Response:       { "message": { "content": "..." }, "eval_count": 512, ... }
    Typical time:   ~2-8s inference (depends on output length), ~2-8s total

    Hardware path:
    +-------------------+     localhost:11434      +-------------------+
    | Mac Studio        | ----------------------> | Ollama            |
    | M2 Ultra, 192GB   |     POST /api/chat      | qwen3.5:27b      |
    | unified memory    | <---------------------- | loaded in unified |
    | lex-ollama        |     200 OK + message    | memory (~16GB)    |
    +-------------------+                         +-------------------+

    Note: Mac Studio unified memory means model loads are fast (no PCIe transfer).
    The M2 Ultra can hold qwen3.5:27b + nomic-embed-text + llama3.2 simultaneously.


  SCENARIO C: A100 GPU server — embed (mxbai-embed-large)
  ========================================================

    Routing key:    llm.request.ollama.embed.mxbai-embed-large
    Queue:          llm.request.ollama.embed.mxbai-embed-large  [quorum]
    Runner:         Ollama::Client#embed(model: 'mxbai-embed-large', input: '...')
    Ollama HTTP:    POST /api/embed  { "model": "mxbai-embed-large", "input": "..." }
    Response:       { "embeddings": [[0.023, -0.891, ...]], "prompt_eval_count": 128 }
    Typical time:   ~15ms inference (A100 is faster), ~95ms total

    Hardware path:
    +-------------------+     localhost:11434      +-------------------+
    | GPU Server        | ----------------------> | Ollama            |
    | 8x A100 80GB      |     POST /api/embed     | mxbai-embed-large |
    | PCIe / NVLink     | <---------------------- | loaded in GPU 0   |
    | lex-ollama        |     200 OK + vector     | VRAM (~670MB)     |
    +-------------------+                         +-------------------+

    Note: Same lex-ollama code, same Ollama API. The only difference is Ollama
    talks to NVIDIA CUDA instead of Apple Metal. lex-ollama doesn't know or care.


  SCENARIO D: H100 GPU server — chat (qwen3.5:27b)
  ==================================================

    Routing key:    llm.request.ollama.chat.qwen3.5.27b
    Queue:          llm.request.ollama.chat.qwen3.5.27b  [quorum]
    Runner:         Ollama::Client#chat(model: 'qwen3.5:27b', messages: [...])
    Ollama HTTP:    POST /api/chat  { "model": "qwen3.5:27b", "messages": [...] }
    Response:       { "message": { "content": "..." }, "eval_count": 512, ... }
    Typical time:   ~0.5-3s inference (H100 much faster), ~0.6-3s total

    Hardware path:
    +-------------------+     localhost:11434      +-------------------+
    | GPU Server        | ----------------------> | Ollama            |
    | 8x H100 80GB      |     POST /api/chat      | qwen3.5:27b      |
    | NVLink + NVSwitch | <---------------------- | loaded in GPU 0-1 |
    | lex-ollama        |     200 OK + message    | VRAM (~16GB)      |
    +-------------------+                         +-------------------+

    Note: Same queue as Scenario B! If both a Mac Studio and an H100 server
    subscribe to llm.request.ollama.chat.qwen3.5.27b, RabbitMQ round-robins
    between them. The H100 finishes faster, so it naturally picks up more work.


  SCENARIO E: generate (raw completion, no chat format)
  ======================================================

    Routing key:    llm.request.ollama.generate.llama3.2
    Queue:          llm.request.ollama.generate.llama3.2  [quorum]
    Runner:         Ollama::Client#generate(model: 'llama3.2', prompt: '...')
    Ollama HTTP:    POST /api/generate  { "model": "llama3.2", "prompt": "..." }
    Response:       { "response": "...", "eval_count": 256, ... }

    Same flow. Only difference from chat: uses `prompt:` instead of `messages:`,
    hits /api/generate instead of /api/chat.
```

```
  SIDE-BY-SIDE: What lex-ollama sees on each hardware type
  =========================================================

  The point: lex-ollama's code path is IDENTICAL. Ollama abstracts the GPU.

                    Mac Studio (M2 Ultra)          A100/H100 Server
                    ----------------------         -------------------
  OS:               macOS                          Linux
  GPU API:          Apple Metal                    NVIDIA CUDA
  Ollama binary:    ollama (arm64)                 ollama (amd64)
  Ollama listens:   localhost:11434                localhost:11434
  lex-ollama sees:  localhost:11434                localhost:11434
  HTTP API:         identical                      identical
  Response JSON:    identical                      identical
  AMQP flow:        identical                      identical

  The ONLY observable difference is inference speed:
  +-------------------------------------------------------------------+
  |  Operation          | Mac Studio M2 Ultra | A100 80GB  | H100 80GB |
  |---------------------|---------------------|------------|-----------|
  |  embed (768-dim)    | ~40ms               | ~15ms      | ~10ms     |
  |  chat (512 tokens)  | ~2-8s               | ~1-4s      | ~0.5-3s   |
  |  generate (256 tok) | ~1-4s               | ~0.5-2s    | ~0.3-1.5s |
  +-------------------------------------------------------------------+

  Faster nodes drain the queue faster -> naturally get more work.
  No scheduling logic needed. AMQP round-robin + prefetch=1 handles it.
```

```
  MIXED FLEET: Realistic deployment with all scenarios running simultaneously
  ============================================================================

  Agent nodes (laptops, services, CI runners)
    all publish to llm.request exchange
        |
        v
  +------------------------------------------------------------------+
  |  Exchange: llm.request (topic, durable)                          |
  |                                                                  |
  |  Bindings:                                                       |
  |    llm.request.ollama.embed.nomic-embed-text  --> Queue A        |
  |    llm.request.ollama.embed.mxbai-embed-large --> Queue B        |
  |    llm.request.ollama.chat.qwen3.5.27b        --> Queue C        |
  |    llm.request.ollama.chat.llama3.2           --> Queue D        |
  |    llm.request.ollama.generate.llama3.2       --> Queue E        |
  +------------------------------------------------------------------+
        |         |         |         |         |
        v         v         v         v         v

  Queue A       Queue B   Queue C   Queue D   Queue E
  (embed/       (embed/   (chat/    (chat/    (generate/
   nomic)        mxbai)    qwen)     llama)    llama)
    |              |         |         |         |
    |   +----------+         |         +----+----+
    |   |                    |              |
    v   v                    v              v
  +----------+         +----------+    +----------+
  | Mac      |         | H100     |    | A100     |
  | Studio 1 |         | Server 1 |    | Server 1 |
  |          |         |          |    |          |
  | Workers: |         | Workers: |    | Workers: |
  |  embed/  |         |  chat/   |    |  chat/   |
  |   nomic  |         |   qwen   |    |   llama  |
  |  embed/  |         |          |    |  generate|
  |   mxbai  |         |          |    |   /llama |
  +----------+         +----------+    +----------+
       |                    |               |
       v                    v               v
  Ollama :11434       Ollama :11434    Ollama :11434

  In this deployment:
  - Mac Studio 1 handles ALL embedding work (both models loaded, plenty of memory)
  - H100 Server 1 handles heavy chat inference (qwen3.5:27b needs fast GPU)
  - A100 Server 1 handles llama3.2 chat + generate (lighter model, A100 is sufficient)
  - Each node only subscribes to queues for models it actually has loaded
  - If Mac Studio 1 goes down, embed queues accumulate until it comes back
    (or another node subscribes to those queues)
```


## 8. What Each Component Owns (Final Architecture)

```
  +------------------------------------------------------------------+
  |                        GPU WORKER NODE                            |
  |                    (H100, A100, Mac Studio, MacBook)              |
  |                                                                   |
  |  +------------------------------------------------------------+  |
  |  |  lex-ollama                                                 |  |
  |  |                                                             |  |
  |  |  Transport/                                                 |  |
  |  |    Exchange: references Legion::LLM::Fleet::Exchange        |  |
  |  |    Queue: per type+model (auto-delete)                      |  |
  |  |                                                             |  |
  |  |  Actor/                                                     |  |
  |  |    ModelWorker (subscription, one per configured model)     |  |
  |  |      prefetch: 1, consumer priority from settings           |  |
  |  |                                                             |  |
  |  |  Runners/                                                   |  |
  |  |    Fleet#handle_request -> dispatches to Chat/Embed/Generate|  |
  |  |    Chat#chat            -> HTTP to Ollama                   |  |
  |  |    Embeddings#embed     -> HTTP to Ollama                   |  |
  |  |    Completions#generate -> HTTP to Ollama                   |  |
  |  +------------------------------------------------------------+  |
  |                                                                   |
  |  Only needs: lex-ollama + legion-transport                        |
  |  No legion-llm, no legion-data, no DB                             |
  +------------------------------------------------------------------+

  +------------------------------------------------------------------+
  |                    CLOUD API WORKER NODE                           |
  |                (AWS VPC, credentialed gateway)                     |
  |                                                                   |
  |  +------------------------------------------------------------+  |
  |  |  lex-bedrock / lex-claude / lex-openai (same pattern)       |  |
  |  |                                                             |  |
  |  |  Transport/                                                 |  |
  |  |    Exchange: references Legion::LLM::Fleet::Exchange        |  |
  |  |    Queue: per type+model (auto-delete)                      |  |
  |  |                                                             |  |
  |  |  Actor/                                                     |  |
  |  |    ModelWorker (subscription, one per configured model)     |  |
  |  |      prefetch: 1, consumer priority from settings           |  |
  |  |                                                             |  |
  |  |  Runners/                                                   |  |
  |  |    Fleet#handle_request -> calls provider API client        |  |
  |  +------------------------------------------------------------+  |
  +------------------------------------------------------------------+

  +------------------------------------------------------------------+
  |                      REQUESTING NODE                              |
  |               (laptop, service, CI runner, agent)                 |
  |                                                                   |
  |  +------------------------------------------------------------+  |
  |  |  legion-llm (core library)                                  |  |
  |  |                                                             |  |
  |  |  Router                                                     |  |
  |  |    - tier resolution: [local, fleet, direct] (configurable) |  |
  |  |    - provider + model resolution                            |  |
  |  |    - escalation on failure                                  |  |
  |  |                                                             |  |
  |  |  Fleet::Dispatcher                                          |  |
  |  |    - builds routing key: llm.request.<provider>.<type>.<m>  |  |
  |  |    - publishes with mandatory: true + publisher confirms    |  |
  |  |    - handles basic.return (no queue) → skip to next tier    |  |
  |  |    - handles basic.nack (queue full) → skip to next tier    |  |
  |  |    - waits on ReplyDispatcher future (per-request timeout)  |  |
  |  |                                                             |  |
  |  |  Fleet::ReplyDispatcher                                     |  |
  |  |    - process-singleton                                      |  |
  |  |    - Concurrent::Map: correlation_id → Future               |  |
  |  |    - one reply queue per process (llm.fleet.reply.<hex>)    |  |
  |  |                                                             |  |
  |  |  Metering.emit()                                            |  |
  |  |    - publishes to llm.metering exchange (fire-and-forget)   |  |
  |  |                                                             |  |
  |  |  Audit.emit_prompt() / Audit.emit_tools()                   |  |
  |  |    - publishes to llm.audit exchange (fire-and-forget)      |  |
  |  +------------------------------------------------------------+  |
  +------------------------------------------------------------------+

  +------------------------------------------------------------------+
  |                        DB NODE                                    |
  |                                                                   |
  |  +------------------------------------------------------------+  |
  |  |  lex-llm-ledger                                             |  |
  |  |                                                             |  |
  |  |  Ledger::Metering                                           |  |
  |  |    MeteringWriter actor → llm.metering.write queue          |  |
  |  |    SpoolFlush actor (60s interval)                          |  |
  |  |    → INSERT INTO metering_records                           |  |
  |  |                                                             |  |
  |  |  Ledger::Prompts                                            |  |
  |  |    PromptWriter actor → llm.audit.prompts queue             |  |
  |  |    → INSERT INTO prompt_records (with retention policy)     |  |
  |  |                                                             |  |
  |  |  Ledger::Tools                                              |  |
  |  |    ToolWriter actor → llm.audit.tools queue                 |  |
  |  |    → INSERT INTO tool_records                               |  |
  |  |                                                             |  |
  |  |  Ledger::Usage                                              |  |
  |  |    UsageReporter: budget_check, summary, top_consumers      |  |
  |  |    ProviderStats: circuit breaker health                    |  |
  |  +------------------------------------------------------------+  |
  +------------------------------------------------------------------+
```


## 9. Publisher Feedback: Three Layers

```
  Fleet::Dispatcher.dispatch()
    │
    │  channel.confirm_select
    │  channel.on_return { |...| fulfill future with :no_fleet_queue }
    │
    │  publish(mandatory: true, priority: msg_priority)
    │
    ├── basic.return?
    │     No queue exists (workers never started / auto-deleted)
    │     → { error: :no_fleet_queue }
    │     → ~1ms, Router tries next tier
    │
    ├── basic.nack?
    │     Queue full (policy: overflow = reject-publish)
    │     → { error: :fleet_backpressure }
    │     → ~1ms, Router tries next tier
    │
    ├── basic.ack → message queued, wait on future:
    │     │
    │     ├── Reply arrives (normal)
    │     │     ReplyDispatcher matches correlation_id
    │     │     → success, return response
    │     │
    │     └── Timeout fires (worker slow/stuck)
    │           future.value!(timeout) raises
    │           → { error: :fleet_timeout }
    │           → Router tries next tier
    │
    └── Timeout values (per request type):
          embed:    10s
          chat:     30s
          generate: 30s


  RabbitMQ Policies (applied externally, not in code):

  ┌─────────────────────────────────────────────────────────┐
  │  Priority 100: fleet-base                               │
  │  Pattern:      ^llm\.request\.                          │
  │  max-length:   100                                      │
  │  overflow:     reject-publish                           │
  │  x-max-priority: 10                                     │
  ├─────────────────────────────────────────────────────────┤
  │  Priority 200: fleet-ollama                             │
  │  Pattern:      ^llm\.request\.ollama\.                  │
  │  max-length:   200      (GPU inference is fast)         │
  │  message-ttl:  60000    (60s — reasonable local max)    │
  │  overflow:     reject-publish                           │
  │  x-max-priority: 10                                     │
  ├─────────────────────────────────────────────────────────┤
  │  Priority 200: fleet-anthropic                          │
  │  Pattern:      ^llm\.request\.anthropic\.               │
  │  max-length:   20       (API proxy, don't hoard)        │
  │  message-ttl:  500000   (500s — big Opus calls)         │
  │  overflow:     reject-publish                           │
  │  x-max-priority: 10                                     │
  ├─────────────────────────────────────────────────────────┤
  │  Priority 200: fleet-bedrock                            │
  │  Pattern:      ^llm\.request\.bedrock\.                 │
  │  max-length:   20                                       │
  │  message-ttl:  300000   (300s)                          │
  │  overflow:     reject-publish                           │
  │  x-max-priority: 10                                     │
  └─────────────────────────────────────────────────────────┘
```


## 10. Consumer Priority + Message Priority

```
  CONSUMER PRIORITY: Who gets the message
  ========================================

  Queue: llm.request.ollama.chat.qwen3.5.27b
    3 consumers, prefetch=1 each:

    ┌──────────────────────────────────────────────────┐
    │  H100 Server    (consumer priority: 10)  ◄── preferred    │
    │  Mac Studio     (consumer priority: 5)   ◄── fallback     │
    │  Dev MacBook    (consumer priority: 1)   ◄── overflow     │
    └──────────────────────────────────────────────────┘

    Message arrives:
      H100 idle?     → deliver to H100       (handles ~70% of traffic)
      H100 busy?
      Mac Studio idle? → deliver to Mac Studio (handles ~25%)
      Mac Studio busy?
      MacBook idle?    → deliver to MacBook    (handles ~5%)
      All busy?        → message waits in queue

    prefetch=1 is critical: ensures a fast consumer doesn't hoard
    messages while slower consumers sit idle.


  MESSAGE PRIORITY: Which message goes first
  ============================================

  Queue: llm.request.ollama.embed.nomic-embed-text
    x-max-priority: 10 (from policy)

    Messages queued (worker is busy):
    ┌──────────────────────────────────────────────────┐
    │  [pri 8] Agent: embed for active conversation    │ ◄── first out
    │  [pri 5] Pipeline: step #42 embedding            │
    │  [pri 2] Batch: embed job #4417                  │
    │  [pri 2] Batch: embed job #4418                  │
    │  [pri 2] Batch: embed job #4419                  │ ◄── last out
    └──────────────────────────────────────────────────┘

    Priority scale:
      9-10  Reserved (system/emergency)
      7-8   User-facing, interactive (agent chat, real-time)
      4-6   Normal operational (pipelines, scheduled tasks)
      1-3   Background batch (bulk embedding, offline)
      0     Best-effort (speculative prefetch)

    A user talking to an agent never waits behind batch jobs.
```

## 11. Message Context Propagation: End-to-End ID Flow

Shows how `message_context` carries conversation and message identity through every
step, from user input to DB persistence. Every AMQP message carries the same struct.

```
USER IN INTERLINK (conv_1234567)
  │
  │  User types: "What files are in src?"
  │  Previous assistant message was msg_004
  │
  v
LEGION-LLM PIPELINE
  │
  │  Builds message_context (ONCE, HERE):
  │  ┌──────────────────────────────────────┐
  │  │ conversation_id:   conv_1234567      │
  │  │ message_id:        msg_005           │ ← the user's message
  │  │ parent_message_id: msg_004           │ ← what it replies to
  │  │ message_seq:       5                 │
  │  │ request_id:        req_abc123        │ ← pipeline instance
  │  │ exchange_id:       (set per-hop)     │
  │  └──────────────────────────────────────┘
  │
  │  This struct is COPIED VERBATIM to every downstream message.
  │  Only exchange_id changes (per-hop).
  │
  ├───────────────────────────────────────────────────────────────────┐
  │                                                                   │
  v                                                                   │
MSG 1: Fleet Request                                                  │
  AMQP message_id:      req_abc123                                    │
  AMQP correlation_id:  req_abc123                                    │
  Header: x-legion-llm-conversation-id: conv_1234567                  │
  Header: x-legion-llm-message-id:      msg_005                      │
  Header: x-legion-llm-request-id:      req_abc123                   │
  Body:   message_context: { ..., exchange_id: exch_001 }             │
  Body:   system: "You are a helpful assistant."                      │
  Body:   messages: [{ role: user, content: "What files..." }]        │
  │                                                                   │
  v                                                                   │
FLEET WORKER (GPU)                                                    │
  │  Copies message_context from request                              │
  │  Calls Ollama, gets response                                      │
  │  Creates msg_006 (assistant response)                             │
  │                                                                   │
  v                                                                   │
MSG 2: Fleet Response                                                 │
  AMQP message_id:      resp_def456                                   │
  AMQP correlation_id:  req_abc123     ← same as request              │
  Header: x-legion-llm-conversation-id: conv_1234567                  │
  Header: x-legion-llm-message-id:      msg_005                      │
  Body:   message_context: { ..., exchange_id: exch_001 }             │
  Body:   id: resp_def456                                             │
  Body:   response_message_id: msg_006                                │
  Body:   message: { role: assistant, content: "..." }                │
  │                                                                   │
  v                                                                   │
REQUESTER RECEIVES RESPONSE                                           │
  │                                                                   │
  ├── Emits metering ─────────────────────────────────────────────────┤
  │                                                                   │
  v                                                                   │
MSG 4: Metering Event                                                 │
  AMQP message_id:      meter_ghi789                                  │
  AMQP correlation_id:  req_abc123     ← links to request             │
  Header: x-legion-llm-conversation-id: conv_1234567                  │
  Header: x-legion-llm-message-id:      msg_005                      │
  Body:   message_context: { ..., exchange_id: exch_001 }             │
  Body:   input_tokens: 42, output_tokens: 28, cost_usd: 0.0         │
  │                                                                   │
  v                                                                   │
LEX-LLM-LEDGER (DB NODE)                                              │
  INSERT INTO metering_records (                                      │
    conversation_id, message_id, request_id, exchange_id,             │
    input_tokens, output_tokens, cost_usd, ...                        │
  )                                                                   │
                                                                      │
  ├── Emits prompt audit ─────────────────────────────────────────────┤
  │                                                                   │
  v                                                                   │
MSG 5: Prompt Audit (encrypted)                                       │
  AMQP message_id:      audit_prompt_jkl012                           │
  AMQP correlation_id:  req_abc123                                    │
  Header: x-legion-llm-conversation-id: conv_1234567                  │
  Header: x-legion-llm-message-id:      msg_005                      │
  Header: x-legion-classification:      internal                      │
  Header: x-legion-retention:           default                       │
  Body:   message_context: { ..., exchange_id: exch_001 }             │
  Body:   response_message_id: msg_006                                │
  Body:   request: { system, messages, tools, ... }                   │
  Body:   response: { message, stop, tools, ... }                     │
  │                                                                   │
  v                                                                   │
LEX-LLM-LEDGER (DB NODE)                                              │
  INSERT INTO prompt_records (                                        │
    conversation_id, message_id, response_message_id,                 │
    request_id, exchange_id, ...                                      │
  )                                                                   │
                                                                      │
  ├── If tool calls, emits tool audit ────────────────────────────────┘
  │
  v
MSG 6: Tool Audit (encrypted)
  AMQP message_id:      audit_tool_mno345
  AMQP correlation_id:  req_abc123
  Header: x-legion-llm-conversation-id: conv_1234567
  Header: x-legion-llm-message-id:      msg_005
  Header: x-legion-tool-name:           list_files
  Body:   message_context: { ..., exchange_id: exch_004 }  ← tool's hop
  Body:   tool_call: { name, arguments, result, duration_ms }
  │
  v
LEX-LLM-LEDGER (DB NODE)
  INSERT INTO tool_records (
    conversation_id, message_id, request_id, exchange_id,
    tool_name, ...
  )


RESULT: Every DB record traces back to conv_1234567 / msg_005 / req_abc123.

  "What happened when I sent msg_005?"
    → metering:  1 record  (tokens, cost, latency)
    → audit:     1 prompt  (full request + response)
    → tools:     1 record  (list_files call + result)
    All linked by message_context.
```


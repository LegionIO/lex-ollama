# Fleet LLM Architecture Design

**Date**: 2026-04-08
**Author**: Matthew Iverson (@Esity)
**Status**: Draft
**Scope**: legion-llm, lex-ollama, lex-llm-ledger (new), lex-llm-gateway (decomposed)

---

## Problem Statement

The current fleet architecture in lex-llm-gateway funnels all LLM requests through a single
`llm.inference.process` queue with one generic `InferenceWorker`. This means:

- No model-level routing — a request for `nomic-embed-text` and `qwen3.5:27b` compete in the same queue
- No provider-level routing — Ollama GPU requests and Bedrock API proxying share the same path
- No hardware affinity — can't prefer H100s over MacBooks for heavy inference
- No backpressure signaling — publishers don't know if workers are alive, dead, or overloaded
- GPU worker nodes must run the full Legion runtime + lex-llm-gateway
- Metering, fleet dispatch, audit, and usage reporting are all tangled in one extension

## Design Goals

1. Model-specific queues with provider-scoped routing keys
2. Three-tier routing: local -> fleet -> direct (configurable order)
3. Publisher feedback via mandatory + publisher confirms + policy-based backpressure
4. Consumer priority so dedicated GPUs are preferred over opportunistic laptop workers
5. Message priority so user-facing requests jump ahead of batch jobs
6. Clean decomposition: legion-llm owns schemas/dispatch/metering-emission, extensions own consumption/persistence
7. Fleet workers only need lex-ollama + legion-transport — no full Legion runtime required

---

## Architecture Overview

### Three-Tier Routing

```
Tier 1: :local
  Model available on localhost (e.g., Ollama running, model loaded)
  → call directly, zero network hops, zero cost

Tier 2: :fleet
  Model available on a fleet worker via AMQP
  Worker might be:
    - GPU server (H100/A100) running Ollama         (self-hosted inference)
    - Mac Studio running Ollama                      (self-hosted inference)
    - Developer MacBook running Ollama               (opportunistic)
    - Process in AWS VPC calling Bedrock             (cloud API proxy)
    - Node with Anthropic/OpenAI API key             (cloud API proxy)
  All are fleet. The provider in the routing key determines what the worker does.
  → publish to llm.request.<provider>.<type>.<model>

Tier 3: :direct
  This node has API credentials → call the cloud API directly
  → call Bedrock/Anthropic/OpenAI/Gemini from this process
```

Tier order is configurable per node:

```yaml
legion:
  llm:
    routing:
      tier_priority: [local, fleet, direct]     # default

      # AWS CI runner (has IAM role, same VPC as Bedrock — direct is fastest)
      # tier_priority: [local, direct, fleet]

      # India office laptop (no GPU, no API keys, fleet workers in us-east-2)
      # tier_priority: [fleet]

      # Air-gapped / paranoid mode (never call cloud APIs)
      # tier_priority: [local, fleet]

      # Developer laptop in MN (has Ollama + API keys)
      # tier_priority: [local, fleet, direct]
```

Why this order matters — India developer needing sonnet-4-6:

```
Direct path:  India laptop → regional hub → SDWAN → Minneapolis →
              datacenter → web tower → internet → api.anthropic.com
              Round trip: 800-1900ms

Fleet path:   India laptop → AMQP (~50ms) →
              Bedrock fleet worker in us-east-2 → Bedrock API (<1ms, same VPC)
              Round trip: ~50ms + API time

Fleet is 10-30x faster for remote teams.
```

### Routing Key Schema

```
llm.request.<provider>.<type>.<model>
```

| Segment    | Values                              | Notes                                  |
|------------|-------------------------------------|----------------------------------------|
| `provider` | `ollama`, `bedrock`, `anthropic`,   | Determines which client the worker uses |
|            | `openai`, `gemini`, `xai`           |                                        |
| `type`     | `chat`, `embed`, `generate`         | Maps to a specific runner method        |
| `model`    | sanitized model name                | `:` replaced with `.` for AMQP rules   |

Examples:

```
llm.request.ollama.chat.qwen3.5.27b            → GPU worker, Ollama chat
llm.request.ollama.embed.nomic-embed-text       → GPU worker, Ollama embed
llm.request.ollama.embed.mxbai-embed-large      → GPU worker, Ollama embed
llm.request.ollama.generate.llama3.2            → GPU worker, Ollama generate
llm.request.bedrock.chat.sonnet-4-6             → AWS VPC worker, Bedrock API
llm.request.anthropic.chat.sonnet-4-6           → API key worker, Anthropic direct
llm.request.openai.chat.gpt-4o                  → API key worker, OpenAI API
```

Bedrock and Anthropic are separate queues for the same model because:
- Different auth (SigV4 vs API key)
- Different rate limits (AWS account vs Anthropic account)
- Different compliance (Bedrock is region-locked, Anthropic is not)
- Different cost
- A worker with AWS creds can't serve Anthropic requests and vice versa

### Queue Topology

```
Exchange: llm.request (topic, durable)
  │
  ├── llm.request.ollama.chat.qwen3.5.27b        → Queue (auto-delete)
  ├── llm.request.ollama.embed.nomic-embed-text   → Queue (auto-delete)
  ├── llm.request.ollama.embed.mxbai-embed-large  → Queue (auto-delete)
  ├── llm.request.bedrock.chat.sonnet-4-6         → Queue (auto-delete)
  ├── llm.request.anthropic.chat.sonnet-4-6       → Queue (auto-delete)
  └── llm.request.openai.chat.gpt-4o             → Queue (auto-delete)

Reply: default exchange ('')
  └── llm.fleet.reply.<hex>                       → Queue (auto-delete, one per process)

Metering: llm.metering (topic, durable)
  └── llm.metering.write                          → Queue (durable, consumed by lex-llm-ledger)

Audit: llm.audit (topic, durable)
  ├── llm.audit.prompts                           → Queue (durable, consumed by lex-llm-ledger)
  └── llm.audit.tools                             → Queue (durable, consumed by lex-llm-ledger)
```

Queues are auto-delete — created when a worker subscribes, deleted when the last consumer
disconnects AND the queue is empty. This means `mandatory: true` on publish gives instant
feedback when no workers exist for a given model.

---

## Publisher Feedback: Three Layers

Publishers (the requesting node's Fleet dispatcher in legion-llm) get fast feedback about
whether their fleet request will be served, without polling or caching.

### Layer 1: mandatory + basic.return (~1ms)

No queue exists for the routing key (workers never started, or all disconnected and queue
auto-deleted after draining).

```
Publisher: basic.publish(mandatory: true)
Broker:    no queue matches routing key
           → basic.return to publisher
Publisher: ReplyDispatcher fulfills future with { error: :no_fleet_queue }
Router:    falls through to next tier
```

### Layer 2: reject-publish + basic.nack (~1ms)

Queue exists but is full — workers are overloaded, stuck, or dead with messages piled up
(auto-delete hasn't fired because queue isn't empty yet).

```
Publisher: basic.publish
Broker:    queue at max-length, overflow: reject-publish
           → basic.nack to publisher
Publisher: ReplyDispatcher fulfills future with { error: :fleet_backpressure }
Router:    falls through to next tier
```

### Layer 3: Client-side timeout (per-request)

Message was accepted and queued, but the worker is taking too long.

```
Publisher: basic.publish → basic.ack (message queued)
           future.value!(timeout)
           ... timeout fires ...
Publisher: { error: :fleet_timeout }
Router:    falls through to next tier
```

Client timeout is per-request based on expected work:

```yaml
legion:
  llm:
    fleet:
      timeouts:
        embed: 10        # embeddings are fast
        chat: 30         # normal chat
        generate: 30     # normal generation
        default: 30      # fallback
```

### Publisher Confirm Setup

```ruby
# In legion-llm Fleet dispatcher (set up once per channel)
channel.confirm_select

channel.on_return do |return_info, properties, payload|
  correlation_id = properties[:correlation_id]
  ReplyDispatcher.fulfill(correlation_id, { routed: false, error: :no_fleet_queue })
end

# On publish:
channel.default_exchange.publish(
  payload,
  routing_key:    'llm.request.ollama.chat.qwen3.5.27b',
  mandatory:      true,
  priority:       message_priority,
  reply_to:       reply_queue_name,
  correlation_id: correlation_id,
  content_type:   'application/json'
)
```

### Combined Flow

```
Fleet.dispatch()
  │
  ├─ publish with mandatory: true, publisher confirms
  │
  ├─ basic.return?     → no queue exists         → { error: :no_fleet_queue }     ~1ms
  ├─ basic.nack?       → queue full              → { error: :fleet_backpressure } ~1ms
  ├─ basic.ack?        → message queued, wait:
  │                        ├─ response arrives    → success
  │                        └─ timeout fires       → { error: :fleet_timeout }
  │
  └─ Router: on any error, try next tier in tier_priority
```

---

## RabbitMQ Policies

Policies are applied externally (Terraform, management UI, or CLI) — not declared in code.
They provide operational control over queue behavior without redeploying workers.

### Base Policy (all fleet queues)

```
Name:       fleet-base
Pattern:    ^llm\.request\.
Priority:   100
Apply to:   queues
Definition:
  max-length:     100
  overflow:        reject-publish
  x-max-priority:  10
```

All fleet queues get: max 100 messages, reject when full, 10 priority levels.

### Provider-Specific Overrides

```
Name:       fleet-ollama
Pattern:    ^llm\.request\.ollama\.
Priority:   200
Apply to:   queues
Definition:
  max-length:      200           # GPU inference is fast, can queue more
  message-ttl:     60000         # 60s — local GPU, reasonable max
  overflow:        reject-publish
  x-max-priority:  10

Name:       fleet-anthropic
Pattern:    ^llm\.request\.anthropic\.
Priority:   200
Apply to:   queues
Definition:
  max-length:      20            # API proxy, don't hoard
  message-ttl:     500000        # 500s — big Opus context windows
  overflow:        reject-publish
  x-max-priority:  10

Name:       fleet-bedrock
Pattern:    ^llm\.request\.bedrock\.
Priority:   200
Apply to:   queues
Definition:
  max-length:      20
  message-ttl:     300000        # 300s
  overflow:        reject-publish
  x-max-priority:  10

Name:       fleet-openai
Pattern:    ^llm\.request\.openai\.
Priority:   200
Apply to:   queues
Definition:
  max-length:      20
  message-ttl:     300000
  overflow:        reject-publish
  x-max-priority:  10
```

Higher priority (200) overrides base (100). Provider policies set appropriate TTLs and
queue depths based on the workload characteristics of each provider.

When message TTL expires, the message is simply dropped (no DLX). The client-side timeout
on the requesting node handles the failure. TTL exists primarily to prevent stale messages
from accumulating if a queue persists with no consumers (the auto-delete + non-empty race).

---

## Consumer Priority

RabbitMQ delivers messages to the highest-priority available consumer first. This lets
dedicated GPU servers handle the bulk of traffic while laptops serve as overflow.

### Configuration

```yaml
# Dedicated H100 GPU server
legion:
  ollama:
    fleet:
      consumer_priority: 10      # highest — preferred for all work
    subscriptions:
      - type: chat
        model: "qwen3.5:27b"
      - type: embed
        model: nomic-embed-text

# Mac Studio (dedicated, but slower than H100)
legion:
  ollama:
    fleet:
      consumer_priority: 5
    subscriptions:
      - type: chat
        model: "qwen3.5:27b"
      - type: embed
        model: nomic-embed-text

# Developer MacBook (opportunistic, only when idle)
legion:
  ollama:
    fleet:
      consumer_priority: 1       # lowest — only used when dedicated hardware is busy
    subscriptions:
      - type: chat
        model: "qwen3.5:27b"
```

### Subscription Behavior

```ruby
# In lex-ollama Actor::ModelWorker
channel.prefetch(1)    # one message at a time, always

queue.subscribe(
  manual_ack: true,
  arguments: { 'x-priority' => consumer_priority }   # from settings
)
```

### Dispatch Behavior

```
Queue: llm.request.ollama.chat.qwen3.5.27b
  3 consumers:

  Message arrives →
    H100 (priority 10) idle?     → YES → deliver to H100
    H100 busy (prefetch full)?
    Mac Studio (priority 5) idle? → YES → deliver to Mac Studio
    Mac Studio busy?
    MacBook (priority 1) idle?    → YES → deliver to MacBook
    All busy?                     → message waits in queue

Result: H100 handles ~70% of traffic (fastest GPU, highest priority)
        Mac Studio handles ~25%
        MacBook handles ~5% (overflow only)
```

`prefetch(1)` is critical — without it, a high-priority consumer could prefetch many
messages while a low-priority consumer sits idle. With prefetch=1, each consumer finishes
one message before taking the next, and priority determines who gets the next message.

---

## Message Priority

Different requests have different urgency. A user talking to an agent in real-time should
not wait behind 500 background batch embedding jobs.

### Priority Levels

```
Priority 9-10:  Reserved (system/emergency)
Priority 7-8:   User-facing, interactive (agent chat, real-time embed)
Priority 4-6:   Normal operational (scheduled tasks, pipeline steps)
Priority 1-3:   Background batch (bulk embedding, offline analysis)
Priority 0:     Best-effort (precomputation, speculative prefetch)
```

### Publisher Side

```ruby
# legion-llm Router determines priority based on caller context
Fleet.dispatch(
  routing_key: 'llm.request.ollama.embed.nomic-embed-text',
  priority:    8,     # user-facing agent
  # ...
)

Fleet.dispatch(
  routing_key: 'llm.request.ollama.embed.nomic-embed-text',
  priority:    2,     # background batch job
  # ...
)
```

### Queue Behavior

```
Queue: llm.request.ollama.embed.nomic-embed-text
  x-max-priority: 10 (set by policy)

  Messages waiting (worker is busy):
    [priority 8] agent needs embedding for active conversation  ← delivered first
    [priority 5] pipeline step #42 embedding
    [priority 2] batch embed job #4417
    [priority 2] batch embed job #4418
    [priority 2] batch embed job #4419                          ← delivered last
```

Requires `x-max-priority` set on the queue (handled by the RabbitMQ policies above).

---

## Reply Queue Architecture

Each requesting **process** (not each request) gets one reply queue. All in-flight fleet
requests from that process share the same reply queue, demuxed by `correlation_id`.

### Lifecycle

```
Process starts → first fleet request triggers ReplyDispatcher.ensure_consumer()
  → declares queue: llm.fleet.reply.<hex>  (classic, auto-delete)
  → starts one Bunny consumer
  → consumer lives for process lifetime

Request #1:     correlation_id = "fleet_aaa"  →  map insert  →  reply arrives  →  map delete
Request #2:     correlation_id = "fleet_bbb"  →  map insert  →  reply arrives  →  map delete
...
Request #10000: correlation_id = "fleet_nnn"  →  map insert  →  reply arrives  →  map delete

All replies land on the same queue. ReplyDispatcher demuxes by correlation_id.

Process exits → consumer disconnects → queue auto-deletes
```

### Concurrent Request Handling

```
Thread A: future_a = dispatch(corr_id: "aaa")  →  future_a.value!(30)  [blocking]
Thread B: future_b = dispatch(corr_id: "bbb")  →  future_b.value!(30)  [blocking]

ReplyDispatcher Concurrent::Map:
  "aaa" → future_a
  "bbb" → future_b

Worker 2 finishes first, publishes reply with correlation_id="bbb"
  → ReplyDispatcher.on_delivery: map.delete("bbb") → future_b.fulfill(response)
  → Thread B unblocks with its response

Worker 1 finishes second, publishes reply with correlation_id="aaa"
  → ReplyDispatcher.on_delivery: map.delete("aaa") → future_a.fulfill(response)
  → Thread A unblocks with its response

Order of replies doesn't matter. Each thread gets its own response.
```

### Reply Queue Count

```
Across the fleet:
  laptop-agent-1       →  1 reply queue
  laptop-agent-2       →  1 reply queue
  ci-runner-1          →  1 reply queue
  service-worker-1     →  1 reply queue
                          ──────────────
                          4 reply queues total

100,000 fleet requests = still 4 reply queues.
Reply queue count = process count, not request count.
```

---

## Component Decomposition

### legion-llm (core library — always present)

Owns: schemas, exchanges, routing, fleet dispatch, metering emission, cost estimation.
No actors. No DB writes. No AMQP consumers.

```
Legion::LLM::Router
  - tier resolution: [local, fleet, direct] (configurable order)
  - provider + model resolution
  - escalation chains

Legion::LLM::Fleet
  Legion::LLM::Fleet::Dispatcher
    - builds routing key: llm.request.<provider>.<type>.<model>
    - publishes to llm.request exchange with mandatory: true
    - manages ReplyDispatcher (correlation_id → future)
    - handles basic.return (no queue), basic.nack (queue full), timeout
    - JWT signing via Legion::Crypt (if auth enabled)
  Legion::LLM::Fleet::ReplyDispatcher
    - process-singleton
    - Concurrent::Map of correlation_id → ResolvableFuture
    - single long-lived consumer on llm.fleet.reply.<hex> queue
  Legion::LLM::Fleet::Exchange
    - defines llm.request (topic, durable) — the single source of truth
  Legion::LLM::Fleet::Request < Legion::LLM::Transport::Message
    - carries message_context, system, messages, tools, generation, etc.
    - message_id: 'req_<uuid>', correlation_id: same as message_id
  Legion::LLM::Fleet::Response < Legion::LLM::Transport::Message
    - carries message_context, response message, tokens, routing, cost
    - message_id: 'resp_<uuid>', correlation_id: copied from request
  Legion::LLM::Fleet::Error < Legion::LLM::Transport::Message
    - carries message_context, error code/category/retriable
    - message_id: 'err_<uuid>', correlation_id: copied from request

Legion::LLM::Metering
  Legion::LLM::Metering::Exchange
    - defines llm.metering (topic, durable) — the single source of truth
  Legion::LLM::Metering::Event < Legion::LLM::Transport::Message
    - carries message_context + token counts, latency, cost, billing
    - message_id: 'meter_<uuid>', correlation_id: from fleet request
  Legion::LLM::Metering.emit(event)
    - publishes to llm.metering exchange (fire-and-forget)
    - spools to disk if transport offline
    - drops silently if neither available
  Legion::LLM::Metering::CostEstimator
    - static pricing table for cloud models
    - self-hosted models = $0.00

Legion::LLM::Audit
  Legion::LLM::Audit::Exchange
    - defines llm.audit (topic, durable) — the single source of truth
  Legion::LLM::Audit::PromptEvent < Legion::LLM::Transport::Message
    - carries message_context + full request/response (encrypted body)
    - message_id: 'audit_prompt_<uuid>', always encrypted
  Legion::LLM::Audit::ToolEvent < Legion::LLM::Transport::Message
    - carries message_context + tool call details (encrypted body)
    - message_id: 'audit_tool_<uuid>', always encrypted
  Legion::LLM::Audit.emit_prompt(event)
    - publishes to llm.audit exchange
  Legion::LLM::Audit.emit_tools(event)
    - publishes to llm.audit exchange
```

legion-llm publishes to exchanges regardless of whether any consumers exist.
If nobody is listening, messages evaporate from the exchange. This is by design.

### lex-ollama (fleet worker — GPU nodes)

Owns: Ollama-specific fleet worker subscription, model-specific queue management.
This is what makes a node a fleet worker for Ollama models.

```
Legion::Extensions::Ollama::Transport
  Exchange: LlmRequest (references Legion::LLM::Fleet::Exchange)
  Queue: ModelRequest (one per configured type+model, auto-delete)

Legion::Extensions::Ollama::Actor
  ModelWorker (subscription actor, one per configured model)
    - prefetch: 1
    - consumer priority from settings
    - manual ack

Legion::Extensions::Ollama::Runners::Fleet
  handle_request(payload)
    - validates JWT (if auth enabled)
    - dispatches by request_type: chat → Client#chat, embed → Client#embed,
      generate → Client#generate
    - builds reply envelope
    - publishes reply to reply_to queue via default exchange
    - acks message

Existing runners unchanged:
  Runners::Chat, Runners::Completions, Runners::Embeddings,
  Runners::Models, Runners::Blobs, Runners::S3Models, Runners::Version
```

Fleet worker configuration:

```yaml
legion:
  ollama:
    host: "http://localhost:11434"
    fleet:
      consumer_priority: 10        # H100: 10, Mac Studio: 5, MacBook: 1
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

Other provider extensions (lex-bedrock, lex-claude, lex-openai, etc.) can follow the same
pattern — add a fleet worker actor that subscribes to `llm.request.<their-provider>.*`
queues and calls their respective API client. The architecture is provider-agnostic.

### lex-llm-ledger (new extension — DB nodes only)

Owns: all LLM observability persistence — metering, audit, usage reporting.
Only runs on nodes with database access. Edge nodes never need this.

```
Legion::Extensions::LLM::Ledger::Metering
  Actor: MeteringWriter (subscription, consumes from llm.metering.write)
    - queue binds to Legion::LLM::Metering::Exchange
    - routing_key: "metering.#"
  Runner: write_metering_record(payload)
    - normalizes fields
    - estimates cost_usd via Legion::LLM::Metering::CostEstimator
    - INSERT INTO metering_records
  Actor: SpoolFlush (interval, every 60s)
    - calls Legion::LLM::Metering.flush_spool
    - drains buffered events when transport reconnects

Legion::Extensions::LLM::Ledger::Prompts
  Actor: PromptWriter (subscription, consumes from llm.audit.prompts)
    - queue binds to Legion::LLM::Audit::Exchange
    - routing_key: "audit.prompt.#"
  Runner: write_prompt_record(payload)
    - INSERT INTO prompt_records
    - retention policy enforcement (PHI TTL, auto-purge)

Legion::Extensions::LLM::Ledger::Tools
  Actor: ToolWriter (subscription, consumes from llm.audit.tools)
    - queue binds to Legion::LLM::Audit::Exchange
    - routing_key: "audit.tool.#"
  Runner: write_tool_record(payload)
    - INSERT INTO tool_records
    - links to parent prompt via correlation_id

Legion::Extensions::LLM::Ledger::Usage
  Runner: UsageReporter
    - summary(since:, period:)
    - worker_usage(worker_id:, ...)
    - budget_check(budget_usd:, threshold:, period:)
    - top_consumers(limit:, group_by:)
  Runner: ProviderStats
    - health_report
    - circuit_summary
    - provider_detail(provider:)
```

### lex-llm-gateway (decomposed — no longer exists)

Everything in lex-llm-gateway moves to one of the three components above:

```
lex-llm-gateway component           → New home
─────────────────────────────────    ─────────────────────────
Runners::Fleet (dispatch side)       → Legion::LLM::Fleet::Dispatcher
Runners::FleetHandler (worker side)  → lex-ollama Runners::Fleet
Helpers::ReplyDispatcher             → Legion::LLM::Fleet::ReplyDispatcher
Helpers::Auth                        → Legion::LLM::Fleet (uses Legion::Crypt)
Helpers::Rpc                         → Legion::LLM::Fleet::Dispatcher
Runners::Inference                   → removed (legion-llm pipeline handles this)
Runners::Metering                    → Legion::LLM::Metering
Runners::MeteringWriter              → lex-llm-ledger Ledger::Metering
Helpers::CostEstimator               → Legion::LLM::Metering::CostEstimator
Helpers::UsageQueries                → lex-llm-ledger Ledger::Usage
Runners::UsageReporter               → lex-llm-ledger Ledger::Usage
Runners::ProviderStats               → lex-llm-ledger Ledger::Usage
Actor::InferenceWorker               → lex-ollama Actor::ModelWorker
Actor::MeteringWriter                → lex-llm-ledger Ledger::Metering
Actor::SpoolFlush                    → lex-llm-ledger Ledger::Metering
Transport::Exchanges::Inference      → Legion::LLM::Fleet::Exchange (renamed llm.request)
Transport::Exchanges::Metering       → Legion::LLM::Metering::Exchange
Transport::Queues::InferenceProcess  → removed (replaced by per-model queues)
Transport::Queues::MeteringWrite     → lex-llm-ledger (creates its own queue)
Transport::Messages::InferenceReq    → Legion::LLM::Fleet::Request
Transport::Messages::InferenceResp   → Legion::LLM::Fleet::Reply
Transport::Messages::MeteringEvent   → Legion::LLM::Metering::Event
Client                               → removed (facade, no longer needed)
```

---

## End-to-End Request Flow

### Happy Path: Agent embeds text via fleet GPU

```
AGENT NODE (developer laptop)

  1. lex-synapse calls Legion::LLM.embed(text: "...", model: 'nomic-embed-text')

  2. Router resolves:
     tier_priority: [local, fleet, direct]
     :local → Ollama not installed → skip
     :fleet → Transport connected → try fleet

  3. Fleet::Dispatcher.dispatch()
     - routing_key = "llm.request.ollama.embed.nomic-embed-text"
     - correlation_id = SecureRandom.uuid
     - signs JWT (if auth enabled)
     - registers correlation_id → ResolvableFuture in ReplyDispatcher
     - ensures reply consumer on llm.fleet.reply.<hex>
     - publishes with mandatory: true, priority: 8

  4. basic.ack received → message queued successfully

  5. future.value!(10) — blocks, waiting for reply

                          RABBITMQ

  6. Exchange llm.request routes to queue llm.request.ollama.embed.nomic-embed-text
  7. Delivered to highest-priority idle consumer (H100 server, priority 10)

                          GPU WORKER (H100 server)

  8.  ModelWorker receives message, decodes payload
  9.  Runners::Fleet#handle_request
      - validates JWT (if auth enabled)
      - request_type = 'embed'
  10. Ollama::Client#embed(model: 'nomic-embed-text', input: '...')
  11. Faraday POST http://localhost:11434/api/embed
  12. Ollama GPU inference → 768-dim vector, ~15ms
  13. Build reply: { correlation_id, response: { embeddings: [...] }, tokens }
  14. Publish reply to default exchange, routing_key: llm.fleet.reply.<hex>
  15. basic.ack (message processed, removed from queue)

                          RABBITMQ

  16. Reply delivered to llm.fleet.reply.<hex> queue

                          AGENT NODE (continued)

  17. ReplyDispatcher.on_delivery: matches correlation_id, fulfills future
  18. future returns response
  19. Metering.emit() → llm.metering exchange (fire-and-forget)
  20. Audit.emit_prompt() → llm.audit exchange (fire-and-forget)
  21. Router returns embeddings to caller
  22. lex-synapse stores vector in Apollo

  Total: ~65ms (50ms network + 15ms inference)
```

### Failure: No Fleet Workers (mandatory return)

```
  3. Fleet::Dispatcher publishes with mandatory: true
  4. basic.return — no queue matches routing key
  5. ReplyDispatcher fulfills future: { error: :no_fleet_queue }
  6. Router: fleet failed, try next tier
  7. :direct → has API key? → call cloud API directly

  Total fleet overhead: ~1ms
```

### Failure: Fleet Overloaded (reject-publish)

```
  3. Fleet::Dispatcher publishes
  4. basic.nack — queue at max-length, overflow: reject-publish
  5. ReplyDispatcher fulfills future: { error: :fleet_backpressure }
  6. Router: fleet failed, try next tier

  Total fleet overhead: ~1ms
```

### Failure: Worker Slow/Stuck (timeout)

```
  3. Fleet::Dispatcher publishes
  4. basic.ack — message queued
  5. future.value!(10) — waiting...
  6. 10 seconds pass, no reply
  7. TimeoutError → { error: :fleet_timeout }
  8. Router: fleet failed, try next tier

  Total fleet overhead: 10s (the configured timeout for embed)
```

---

## Node Deployment Profiles

### Developer Laptop (Minnesota)

```yaml
legion:
  llm:
    routing:
      tier_priority: [local, fleet, direct]
  ollama:
    host: "http://localhost:11434"
    fleet:
      consumer_priority: 1          # opportunistic — only overflow work
    subscriptions:
      - type: chat
        model: llama3.2             # small model that fits in 16GB
```

Runs Ollama locally for small models. Subscribes as a low-priority fleet worker.
Can call cloud APIs directly if it has keys.

### Developer Laptop (India)

```yaml
legion:
  llm:
    routing:
      tier_priority: [fleet]        # no local GPU, no API keys
```

No Ollama, no API keys. Everything goes through fleet. Relies on fleet workers
in us-east-2 for all LLM work. If fleet is down, LLM calls fail.

### Dedicated GPU Server (H100)

```yaml
legion:
  ollama:
    host: "http://localhost:11434"
    fleet:
      consumer_priority: 10         # highest — preferred for all work
    subscriptions:
      - type: chat
        model: "qwen3.5:27b"
      - type: chat
        model: llama3.2
      - type: embed
        model: nomic-embed-text
      - type: embed
        model: mxbai-embed-large
      - type: generate
        model: llama3.2
```

Dedicated fleet worker. Subscribes to all models it has loaded.
Does not run lex-llm-ledger (no DB access needed).
Only needs: lex-ollama + legion-transport.

### Mac Studio (Dedicated)

```yaml
legion:
  ollama:
    host: "http://localhost:11434"
    fleet:
      consumer_priority: 5          # below H100, above MacBooks
    subscriptions:
      - type: embed
        model: nomic-embed-text
      - type: embed
        model: mxbai-embed-large
```

Handles embedding workloads. M2 Ultra unified memory holds both embedding
models simultaneously.

### Bedrock Fleet Worker (AWS VPC)

```yaml
legion:
  llm:
    routing:
      tier_priority: [direct]       # always call Bedrock directly (same VPC)
  bedrock:
    region: us-east-2
    fleet:
      consumer_priority: 10
    subscriptions:
      - type: chat
        model: sonnet-4-6
      - type: chat
        model: haiku-4-5
```

Sits in the same VPC as Bedrock. Subscribes to fleet queues so remote nodes
(India, laptops) can route through it. Calls Bedrock directly (<1ms).

### DB Node (Metering + Audit)

```yaml
# Runs lex-llm-ledger, has database access
legion:
  data:
    connection: postgresql://...
```

Runs lex-llm-ledger actors: MeteringWriter, PromptWriter, ToolWriter, SpoolFlush.
Consumes from llm.metering.write, llm.audit.prompts, llm.audit.tools.
Does not run fleet workers.

---

## Mixed Fleet Deployment Diagram

```
  Agent nodes (laptops, services, CI runners)
    publish to llm.request exchange
        │
        v
  ┌──────────────────────────────────────────────────────────────┐
  │  Exchange: llm.request (topic, durable)                      │
  │                                                              │
  │  Policy: fleet-base      (pri 100) max-length: 100           │
  │  Policy: fleet-ollama    (pri 200) max-length: 200, TTL: 60s │
  │  Policy: fleet-bedrock   (pri 200) max-length: 20,  TTL: 300s│
  │  Policy: fleet-anthropic (pri 200) max-length: 20,  TTL: 500s│
  │                                                              │
  │  Queues (auto-delete, created by workers on boot):           │
  │    llm.request.ollama.chat.qwen3.5.27b                       │
  │    llm.request.ollama.embed.nomic-embed-text                 │
  │    llm.request.ollama.embed.mxbai-embed-large                │
  │    llm.request.bedrock.chat.sonnet-4-6                       │
  │    llm.request.bedrock.chat.haiku-4-5                        │
  └──────────────────────────────────────────────────────────────┘
        │              │              │              │
        v              v              v              v
  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐
  │ H100     │  │ Mac      │  │ MacBook  │  │ Bedrock      │
  │ Server   │  │ Studio   │  │ (India)  │  │ Worker       │
  │ pri: 10  │  │ pri: 5   │  │ pri: 1   │  │ (us-east-2)  │
  │          │  │          │  │          │  │ pri: 10       │
  │ chat/    │  │ embed/   │  │ chat/    │  │              │
  │  qwen    │  │  nomic   │  │  qwen    │  │ chat/        │
  │ chat/    │  │ embed/   │  │          │  │  sonnet-4-6  │
  │  llama   │  │  mxbai   │  │          │  │ chat/        │
  │ embed/   │  │          │  │          │  │  haiku-4-5   │
  │  nomic   │  │          │  │          │  │              │
  └──────────┘  └──────────┘  └──────────┘  └──────────────┘
       │              │              │              │
       v              v              v              v
  Ollama :11434  Ollama :11434  Ollama :11434  Bedrock API
  (8x H100)     (M2 Ultra)    (M4 Pro)       (us-east-2)
```

---

## Open Questions

1. **Auth enforcement**: Should JWT auth be required for fleet, or optional (current default)?
   If required, every fleet worker needs Legion::Crypt. If optional, unauthenticated fleet
   requests are possible on trusted networks.

2. **Model sanitization**: `:` → `.` in routing keys (e.g., `qwen3.5:27b` → `qwen3.5.27b`).
   Is this sufficient? Are there other characters in model names that conflict with AMQP
   routing key segments?

3. **Auto-discovery**: Should workers auto-detect which models Ollama has loaded
   (`GET /api/tags`) and subscribe dynamically, or should subscriptions always be explicit
   in settings? Auto-discovery is convenient but makes fleet topology less predictable.

4. **Metering on worker side**: Should fleet workers also emit metering events (inference
   time, GPU utilization), or is requester-side metering sufficient? Worker-side metering
   would give visibility into per-GPU performance.

5. **lex-llm-gateway deprecation timeline**: How fast do we decompose? Big bang or
   incremental migration?

6. **Audit retention**: What are the retention policies for prompt records? PHI TTL caps?
   Per-environment configuration?

7. **Consumer priority values**: Should there be a standard scale, or is per-deployment
   configuration sufficient? Standard: GPU server = 10, Mac Studio = 5, laptop = 1.

---

## Message Context Propagation

Every LLM fleet message carries a `message_context` struct that traces back to the
originating user interaction. Built once at the pipeline entry point, copied verbatim
through all downstream messages (fleet request, response, error, metering, audit).

### ID Hierarchy

```
conversation_id: conv_1234567          ← session (persists across turns)
  └── message.id: msg_005              ← user's message (the turn)
       │   parent_message_id: msg_004  ← what it replies to
       └── request.id: req_abc123      ← pipeline processing instance
            └── exchange_id: exch_001  ← per-hop (provider call, tool exec, retry)
```

### message_context Struct

```
message_context:
  conversation_id:     String     # session ID
  message_id:          String     # triggering user message
  parent_message_id:   String?    # what it replies to
  message_seq:         Integer    # position in conversation
  request_id:          String     # pipeline instance
  exchange_id:         String?    # current hop (set per-leg)
```

This struct appears in the JSON body of all six message types. A subset
(`conversation_id`, `message_id`, `request_id`) is also promoted to AMQP headers
for filtering without parsing the body.

See [Fleet Wire Protocol](2026-04-08-fleet-wire-protocol.md) for the complete AMQP
property mapping, header conventions, and per-message-type specifications.

### Class Hierarchy

All fleet messages inherit from `Legion::LLM::Transport::Message`, which adds
`message_context` propagation and LLM-specific headers to the platform base class:

```
Legion::Transport::Message                    (platform base)
  └── Legion::LLM::Transport::Message         (LLM base — message_context, llm_headers)
       ├── Legion::LLM::Fleet::Request        (type: 'llm.fleet.request')
       ├── Legion::LLM::Fleet::Response       (type: 'llm.fleet.response')
       ├── Legion::LLM::Fleet::Error          (type: 'llm.fleet.error')
       ├── Legion::LLM::Metering::Event       (type: 'llm.metering.event')
       ├── Legion::LLM::Audit::PromptEvent    (type: 'llm.audit.prompt')
       └── Legion::LLM::Audit::ToolEvent      (type: 'llm.audit.tool')
```

---

## Related Documents

- [Fleet Wire Protocol](2026-04-08-fleet-wire-protocol.md) — AMQP envelope mapping,
  platform-wide property standard, message_context, all six message type specs
- [Fleet Architecture Diagrams](../fleet-architecture-diagrams.md) — visual diagrams of
  current state, proposed state, end-to-end flows, queue topology
- [S3 Model Distribution Design](2026-04-01-s3-model-distribution-design.md) — how models
  are distributed to fleet workers via S3
- [LLM Gateway Design](../../../../docs/work/completed_confirmed/2026-03-18-llm-gateway-design.md) —
  original lex-llm-gateway design (being decomposed)
- [Fleet RPC Wait Design](../../../../extensions-core/lex-llm-gateway/docs/plans/2026-03-22-fleet-rpc-wait-design.md) —
  ReplyDispatcher correlation pattern
- [Distributed Fleet Inference Cost Model](../../../../docs/work/completed_confirmed/2026-03-15-distributed-fleet-inference-cost-model.md) —
  executive cost justification for fleet ($31-103M 5-year savings)

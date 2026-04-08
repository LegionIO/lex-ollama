# Fleet Wire Protocol: AMQP Envelope Mapping

**Date**: 2026-04-08
**Author**: Matthew Iverson (@Esity)
**Status**: Draft
**Related**: [Fleet Architecture Design](2026-04-08-fleet-llm-architecture-design.md),
  [LLM Schema Spec](../../../../legion-llm/docs/llm-schema-spec.md)

---

## Problem

`Legion::Transport::Message` already maps most RabbitMQ message properties to methods.
The LLM schema spec defines 32 Request fields and 34 Response fields. Today the fleet
request (`InferenceRequest`) stuffs everything into the JSON body and only uses a handful
of AMQP properties.

We need to ensure fleet messages use AMQP properties correctly — putting routing/delivery
metadata where RabbitMQ can act on it natively, and keeping the payload for application
data only. This makes RabbitMQ more efficient (it can route, expire, prioritize, and DLX
without parsing the body) and aligns with Legion's general transport conventions.

This applies to **all** Legion messages, not just LLM — the principles are the same.

---

## Guiding Principle

```
AMQP properties  → what RabbitMQ needs to ACT on (route, expire, prioritize, deduplicate)
AMQP headers     → what CONSUMERS need to FILTER on without parsing the body
JSON body        → what the APPLICATION needs to EXECUTE the work

No field appears in more than one layer.

Exception: message_context IDs appear in both headers (subset, for filtering/routing)
and body (full struct, for application logic). Classification headers follow the same
pattern. These are intentional — the header carries the routing-relevant subset, the
body carries the full struct.
```

---

## Platform-Wide AMQP Property Standard

This section defines how **all** LegionIO messages should use AMQP 0.9.1 Basic properties.
LLM fleet messages are one instance of this standard, not a special case.

### Property Mapping

| Property | Legion Standard | RabbitMQ Uses It For |
|---|---|---|
| `content_type` | `'application/json'` — always JSON. Never varies per-message-type. | Serialization hint |
| `content_encoding` | `'identity'` \| `'gzip'` \| `'encrypted/cs'` — consumers need this BEFORE parsing the body. | Compression/encryption hint |
| `type` | Dotted namespace: `<domain>.<category>.<action>`. Consumers dispatch on this without parsing the body. RabbitMQ preserves it through DLX. Legacy messages use flat strings (`task`, `heartbeat`); new messages use dotted. | Message type dispatch |
| `message_id` | Sender's unique ID for THIS message. Format: `<prefix>_<uuid>`. NOT task_id (that goes in headers). Globally unique. Enables deduplication on redelivery. | Deduplication |
| `correlation_id` | Links a REPLY to its REQUEST (RPC pattern). Set by requester, copied verbatim onto reply. NOT for business-level correlation (use header `x-legion-trace-correlation-id`). NOT for task chain linking (use header `parent_id`). | Reply matching |
| `reply_to` | Queue name where sender listens for replies. Only set on messages that expect a reply. Replier uses this as routing key on the default exchange `''`. | RPC reply routing |
| `priority` | 0-9 integer. Queue must have `x-max-priority` set. Platform-wide scale (see below). | Queue ordering |
| `expiration` | Per-message TTL in milliseconds (string). "How long is this message useful?" Interacts with queue-level TTL policy — shorter wins. | Per-message TTL |
| `timestamp` | Unix epoch (integer). When the message was CREATED, not published (could be later if spooled). Always set. Never nil. | Age tracking |
| `user_id` | RabbitMQ connection user. RMQ validates this matches the connection. Never override — let the base class set it. This is the AMQP identity, NOT the application user. | Sender validation |
| `app_id` | Which Legion component published this message. Tells you WHO without parsing. | Sender identification |
| `cluster_id` | **DEPRECATED** in AMQP 0.9.1. Do not use. Use header `x-legion-region` instead. | (none) |

### Priority Scale (Platform-Wide)

All Legion messages use the same priority scale:

| Value | Name | Use Cases |
|---|---|---|
| `9` | critical | System ops, escalation, killswitch, cluster control |
| `7` | high | User-facing, real-time, interactive agent |
| `5` | normal | Standard pipeline tasks |
| `2` | low | Background batch, dream-cycle, scheduled |
| `0` | none | Best-effort (heartbeat, gossip, metering) |

### app_id Convention

| Value | Component |
|---|---|
| `'legion'` | Core framework, task dispatch (base default) |
| `'legion-llm'` | LLM pipeline (fleet dispatch, metering emit, audit emit) |
| `'lex-ollama'` | Ollama fleet worker |
| `'lex-bedrock'` | Bedrock fleet worker |
| `'lex-node'` | Heartbeats, cluster control |
| `'lex-mesh'` | Mesh gossip, departure, conflict |
| `'lex-apollo'` | Knowledge queries, ingest, writeback |
| `'lex-llm-ledger'` | Metering/audit DB writer (if it publishes) |

New extensions set `app_id` to their gem name. Base default stays `'legion'` for
backwards compatibility.

### type Convention

| Pattern | Examples |
|---|---|
| Legacy (flat) | `task`, `heartbeat` — existing, don't change until touched |
| New (dotted) | `llm.fleet.request`, `mesh.gossip`, `apollo.query`, `node.cluster.settings` |

New messages always use dotted namespace. Consumer dispatch:
```ruby
case delivery_info.properties.type
when 'llm.fleet.request'  then handle_fleet_request(payload)
when 'llm.fleet.response' then handle_fleet_response(payload)
when 'llm.fleet.error'    then handle_fleet_error(payload)
when 'task'               then handle_legacy_task(payload)
end
```

### message_id Convention

Format: `<prefix>_<uuid>` — prefix identifies message type without parsing.

| Prefix | Message Type |
|---|---|
| `req_` | Fleet request |
| `resp_` | Fleet response |
| `err_` | Fleet error |
| `meter_` | Metering event |
| `audit_prompt_` | Prompt audit |
| `audit_tool_` | Tool audit |
| `task_` | Task message |
| `beat_` | Heartbeat |
| `gossip_` | Mesh gossip |

Base default stays `@options[:task_id]` for backwards compatibility.

### correlation_id Rules

| Message Pattern | correlation_id Value |
|---|---|
| Request (expects reply) | Own `message_id` (requester generates, copies to reply matcher) |
| Reply (response/error) | Copy from the request being replied to |
| Related (metering/audit) | Copy from the request that triggered it |
| Fire-and-forget (heartbeat) | Own `message_id` or nil |
| Legacy task | `parent_id \|\| task_id` (base default, unchanged) |

---

## Platform-Wide Headers

Every Legion message carries these headers, injected by `Legion::Transport::Message#headers`:

### Always Present

```ruby
'legion_protocol_version'           # '2.0'
'x-legion-region'                   # e.g., 'us-east-2'
'x-legion-region-affinity'          # 'prefer_local', 'require_local', 'any'
'x-legion-identity-canonical-name'  # e.g., 'laptop-matt-01'
'x-legion-identity-id'             # e.g., 'node_abc123'
'x-legion-identity-kind'           # 'agent', 'worker', 'service'
'x-legion-identity-mode'           # 'standard', 'lite'
'x-legion-identity-source'         # 'dns', 'vault', 'config'
```

### Task Tracking (Legacy, Present When Set)

```ruby
'task_id', 'parent_id', 'master_id', 'chain_id',
'relationship_id', 'runner_namespace', 'runner_class',
'namespace_id', 'function_id', 'function', 'debug',
'trigger_namespace_id', 'trigger_function_id'
```

Domain-specific headers are added by subclasses via `super.merge(...)`.

---

## Message Context Propagation

### The ID Hierarchy

The LLM schema defines a three-level ID hierarchy (inspired by SIP Call-ID / CSeq / Branch):

```
conversation_id: conv_1234567          ← session (SIP Call-ID)
  │
  ├── message.id: msg_004              ← previous assistant response
  │
  └── message.id: msg_005              ← user just typed this (the TURN)
       │   message.parent_id: msg_004  ← what it replies to
       │
       └── request.id: req_abc123      ← pipeline processing instance
            │
            ├── exchange_id: exch_001  ← first provider call (failed)
            ├── exchange_id: exch_002  ← retry (failed, escalate)
            ├── exchange_id: exch_003  ← escalation (tool_use)
            │    └── exchange_id: exch_004  ← tool:list_files execution
            └── exchange_id: exch_005  ← follow-up (end_turn)
                 │
                 └── message.id: msg_006  ← assistant response (CREATED)
                      message.parent_id: msg_005
```

### message_context Struct

Every LLM fleet message carries a `message_context` block in the JSON body. Built once
at the pipeline entry point, copied verbatim through every downstream message. The only
field that changes per-hop is `exchange_id`.

```
message_context:
  conversation_id:     String     # conv_1234567 — the session
  message_id:          String     # msg_005 — the triggering user message
  parent_message_id:   String?    # msg_004 — what it replies to
  message_seq:         Integer    # 5 — position in conversation
  request_id:          String     # req_abc123 — pipeline processing instance
  exchange_id:         String?    # exch_003 — current hop (set per-leg)
```

This is analogous to OpenTelemetry's `SpanContext` — you propagate it, you don't
reconstruct it. No field mapping, no "does this message type carry conversation_id?"
— they all do, always, via the same struct.

### Context Headers (Subset for Filtering)

Three fields from `message_context` are promoted to AMQP headers so consumers can
filter without parsing the body:

```ruby
'x-legion-llm-conversation-id'  # conv_1234567
'x-legion-llm-message-id'       # msg_005
'x-legion-llm-request-id'       # req_abc123
```

### What message_context Enables

```sql
-- "What happened when I sent msg_005?"
SELECT * FROM audit_prompts WHERE message_id = 'msg_005';
SELECT * FROM metering WHERE message_id = 'msg_005';
SELECT * FROM audit_tools WHERE message_id = 'msg_005';

-- "Total cost for conversation conv_1234567?"
SELECT SUM(cost_usd) FROM metering WHERE conversation_id = 'conv_1234567';

-- "Which exchange failed before escalation?"
SELECT * FROM metering WHERE request_id = 'req_abc123' ORDER BY exchange_id;

-- "Show me the thread: msg_004 → msg_005 → msg_006"
SELECT * FROM audit_prompts
WHERE message_id IN ('msg_004', 'msg_005')
   OR response_message_id IN ('msg_005', 'msg_006');
```

---

## LLM Message Class Hierarchy

```
Legion::Transport::Message                    (platform base)
  └── Legion::LLM::Transport::Message         (LLM base — adds message_context, llm_headers)
       ├── Legion::LLM::Fleet::Request        (type: 'llm.fleet.request')
       ├── Legion::LLM::Fleet::Response       (type: 'llm.fleet.response')
       ├── Legion::LLM::Fleet::Error          (type: 'llm.fleet.error')
       ├── Legion::LLM::Metering::Event       (type: 'llm.metering.event')
       ├── Legion::LLM::Audit::PromptEvent    (type: 'llm.audit.prompt')
       └── Legion::LLM::Audit::ToolEvent      (type: 'llm.audit.tool')
```

### Legion::LLM::Transport::Message (LLM Base)

Subclasses `Legion::Transport::Message`. Adds `message_context` propagation and
LLM-specific headers that every LLM message carries.

```ruby
module Legion
  module LLM
    module Transport
      class Message < ::Legion::Transport::Message
        LLM_ENVELOPE_KEYS = %i[
          message_context routing_key reply_to fleet_correlation_id
          request_type provider model priority ttl
        ].freeze

        def message_context
          @options[:message_context] || {}
        end

        def message
          @options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)
        end

        def message_id
          @options[:message_id] || "#{message_id_prefix}_#{SecureRandom.uuid}"
        end

        def correlation_id
          @options[:fleet_correlation_id] || super
        end

        def app_id
          @options[:app_id] || 'legion-llm'
        end

        def headers
          super.merge(llm_headers).merge(context_headers)
        end

        private

        def message_id_prefix = 'msg'

        def llm_headers
          h = {}
          h['x-legion-llm-provider']       = @options[:provider].to_s     if @options[:provider]
          h['x-legion-llm-model']          = @options[:model].to_s        if @options[:model]
          h['x-legion-llm-request-type']   = @options[:request_type].to_s if @options[:request_type]
          h['x-legion-llm-schema-version'] = '1.0.0'
          h
        end

        def context_headers
          ctx = message_context
          h = {}
          h['x-legion-llm-conversation-id'] = ctx[:conversation_id].to_s if ctx[:conversation_id]
          h['x-legion-llm-message-id']      = ctx[:message_id].to_s      if ctx[:message_id]
          h['x-legion-llm-request-id']      = ctx[:request_id].to_s      if ctx[:request_id]
          h
        end
      end
    end
  end
end
```

### LLM Headers (Added to Every LLM Message)

```ruby
# Routing/model context (filterable without body parsing)
'x-legion-llm-provider'            # 'ollama', 'bedrock', 'anthropic', etc.
'x-legion-llm-model'               # 'qwen3.5:27b' (original, unsanitized)
'x-legion-llm-request-type'        # 'chat', 'embed', 'generate'
'x-legion-llm-schema-version'      # '1.0.0'

# Message context (subset — for filtering/routing)
'x-legion-llm-conversation-id'     # conv_1234567
'x-legion-llm-message-id'          # msg_005
'x-legion-llm-request-id'          # req_abc123
```

---

## Message Type Registry

Six distinct message types in the LLM fleet system:

| Type string | Direction | Exchange | Purpose |
|---|---|---|---|
| `llm.fleet.request` | requester → worker | `llm.request` (topic) | Fleet inference request |
| `llm.fleet.response` | worker → requester | `''` (default) | Successful inference response |
| `llm.fleet.error` | worker → requester | `''` (default) | Worker-side error response |
| `llm.metering.event` | requester → ledger | `llm.metering` (topic) | Token/cost/latency metrics |
| `llm.audit.prompt` | requester → ledger | `llm.audit` (topic) | Full prompt+response audit record |
| `llm.audit.tool` | requester → ledger | `llm.audit` (topic) | Tool call audit record |

---

## Message 1: Fleet Request (`llm.fleet.request`)

**Who publishes**: Requesting node (legion-llm Fleet::Dispatcher)
**Who consumes**: Fleet worker (lex-ollama ModelWorker, lex-bedrock ModelWorker, etc.)
**Exchange**: `llm.request` (topic, durable)
**Routing key**: `llm.request.<provider>.<type>.<model>`
**Queue**: same as routing key (auto-delete, created by worker on boot)

### AMQP Properties

| Property | Value | Notes |
|---|---|---|
| `content_type` | `'application/json'` | |
| `content_encoding` | `'identity'` or `'encrypted/cs'` | Encrypted if cs_encrypt_ready |
| `type` | `'llm.fleet.request'` | |
| `message_id` | `'req_<uuid>'` | Unique request ID, enables deduplication |
| `correlation_id` | `'req_<uuid>'` | Same as message_id (requester-generated, copied to reply) |
| `reply_to` | `'llm.fleet.reply.<hex>'` | Requesting process's reply queue |
| `priority` | `0-9` integer | Mapped from `Request.priority` symbol |
| `expiration` | `'<ms>'` string or nil | From `Request.ttl` (seconds x 1000) |
| `timestamp` | unix epoch | |
| `user_id` | connection user | |
| `app_id` | `'legion-llm'` | |

**Priority mapping** (Request.priority symbol → AMQP integer):

| Symbol | Integer | Use case |
|---|---|---|
| `:critical` | `9` | System operations, escalation |
| `:high` | `7` | User-facing agent, real-time |
| `:normal` | `5` | Standard pipeline tasks |
| `:low` | `2` | Background batch jobs |
| (explicit 0-9) | as-is | Direct control |

**correlation_id** — the fleet correlation ID for reply matching. This is the same as
`message_id` on the request. NOT `Request.tracing.correlation_id` (business-level
grouping, goes in header `x-legion-trace-correlation-id`).

### Headers

```ruby
{
  # --- Standard Legion (from base, always present) ---
  'legion_protocol_version'           => '2.0',
  'x-legion-region'                   => 'us-east-2',
  'x-legion-region-affinity'          => 'prefer_local',
  'x-legion-identity-canonical-name'  => 'laptop-matt-01',
  'x-legion-identity-id'             => 'node_abc123',
  'x-legion-identity-kind'           => 'agent',
  'x-legion-identity-mode'           => 'standard',
  'x-legion-identity-source'         => 'dns',

  # --- LLM routing (from LLM base, all fleet messages) ---
  'x-legion-llm-provider'            => 'ollama',
  'x-legion-llm-model'               => 'qwen3.5:27b',
  'x-legion-llm-request-type'        => 'chat',
  'x-legion-llm-schema-version'      => '1.0.0',

  # --- Message context (from LLM base, all fleet messages) ---
  'x-legion-llm-conversation-id'     => 'conv_1234567',
  'x-legion-llm-message-id'          => 'msg_005',
  'x-legion-llm-request-id'          => 'req_abc123',

  # --- LLM tier (request-specific) ---
  'x-legion-llm-tier'                => 'fleet',

  # --- Tracing (OpenTelemetry propagation) ---
  'x-legion-trace-id'                => 'trace_01HZ...',
  'x-legion-span-id'                 => 'span_01HZ...',
  'x-legion-parent-span-id'          => 'span_01HZ...',
  'x-legion-trace-correlation-id'    => 'ticket-PROJ-1234',

  # --- Classification (compliance, filterable without body parsing) ---
  'x-legion-classification'          => 'internal',
  'x-legion-contains-phi'            => 'false',
  'x-legion-jurisdictions'           => 'us',

  # --- Auth (optional, only if fleet auth enabled) ---
  'x-legion-fleet-token'             => '<JWT, 60s TTL>',
}
```

### JSON Body

```json
{
  "message_context": {
    "conversation_id": "conv_1234567",
    "message_id": "msg_005",
    "parent_message_id": "msg_004",
    "message_seq": 5,
    "request_id": "req_abc123",
    "exchange_id": "exch_001"
  },

  "system": "You are a helpful assistant.",

  "routing": {
    "provider": "ollama",
    "model": "qwen3.5:27b"
  },

  "messages": [
    { "role": "user", "content": "What files are in the src directory?" }
  ],

  "tools": [
    {
      "name": "list_files",
      "description": "List files in a directory",
      "parameters": { "type": "object", "properties": { "path": { "type": "string" } } },
      "source": { "type": "mcp", "server": "filesystem" }
    }
  ],
  "tool_choice": { "mode": "auto" },

  "generation": {
    "temperature": 0.7,
    "top_p": 1.0,
    "top_k": null,
    "seed": null
  },
  "thinking": {
    "enabled": false,
    "budget_tokens": null,
    "effort": null
  },
  "response_format": {
    "type": "text",
    "schema": null
  },
  "stop": {
    "sequences": []
  },
  "tokens": {
    "max": 4096
  },

  "stream": false,
  "context_strategy": "auto",
  "cache": { "strategy": "default" },
  "fork": null,
  "extra": {},
  "idempotency_key": null,

  "modality": {
    "input": ["text"],
    "output": ["text"]
  },

  "metadata": {},

  "caller": {
    "requested_by": {
      "identity": "user:matt",
      "type": "user",
      "credential": "session",
      "name": "Matt Iverson"
    },
    "requested_for": null
  },
  "agent": {
    "id": "gaia",
    "name": "GAIA",
    "type": "autonomous",
    "task_id": "task_abc123",
    "goal": "Consolidate memory chunk"
  },

  "billing": {
    "cost_center": "engineering-platform",
    "budget_id": "budget_q1_2026",
    "spending_cap": 0.50
  },

  "test": null,

  "hooks": {
    "after_response": ["log_to_splunk"]
  },

  "enrichments": {
    "gaia:system_prompt": {
      "content": "user prefers concise answers",
      "duration_ms": 22,
      "timestamp": "2026-04-08T14:30:00Z"
    }
  },
  "predictions": {
    "router:tool_usage": {
      "expected": true,
      "confidence": 0.8,
      "basis": "message contains 'what files'"
    }
  },

  "tracing": {
    "trace_id": "trace_01HZ...",
    "span_id": "span_01HZ...",
    "parent_span_id": "span_01HZ...",
    "correlation_id": "ticket-PROJ-1234",
    "baggage": {}
  },

  "classification": {
    "level": "internal",
    "contains_pii": false,
    "contains_phi": false,
    "jurisdictions": ["us"],
    "retention": "default",
    "consent": null
  }
}
```

### Fields NOT in body (in properties or headers instead)

| LLM Schema Field | AMQP Location | Key/Property |
|---|---|---|
| `Request.id` | property | `message_id` (`req_<uuid>`) |
| `Request.schema_version` | header | `x-legion-llm-schema-version` |
| `Request.priority` | property | `priority` (mapped to int) |
| `Request.ttl` | property | `expiration` (seconds x 1000, string) |
| Fleet correlation_id | property | `correlation_id` (same as message_id) |
| Fleet reply_to | property | `reply_to` |
| Fleet signed_token | header | `x-legion-fleet-token` |

Note: `routing.provider`, `routing.model`, `classification`, and `tracing` appear
in both headers (for RabbitMQ/consumer filtering) and body (for application logic).
Headers carry the routing-relevant subset; body carries the full struct. Workers that
need the full classification read the body; compliance middleware only reads headers.

---

## Message 2: Fleet Response (`llm.fleet.response`)

**Who publishes**: Fleet worker (lex-ollama Runners::Fleet, lex-bedrock, etc.)
**Who consumes**: Requesting node (ReplyDispatcher)
**Exchange**: `''` (AMQP default exchange, implicit binding by queue name)
**Routing key**: `'llm.fleet.reply.<hex>'` (copied from request's `reply_to`)
**Queue**: `llm.fleet.reply.<hex>` (classic, auto-delete, one per requesting process)

### AMQP Properties

| Property | Value | Notes |
|---|---|---|
| `content_type` | `'application/json'` | |
| `content_encoding` | `'identity'` or `'encrypted/cs'` | Match request's encryption |
| `type` | `'llm.fleet.response'` | Distinguishes from error |
| `message_id` | `'resp_<uuid>'` | Unique response ID |
| `correlation_id` | `'req_<uuid>'` | **Same** as request's correlation_id |
| `reply_to` | nil | Replies don't chain |
| `priority` | `0` | Replies don't need queue ordering |
| `expiration` | nil | Replies should be consumed immediately |
| `timestamp` | unix epoch | |
| `user_id` | connection user | |
| `app_id` | `'lex-ollama'` | Worker's component identity |

### Headers

```ruby
{
  # --- Standard Legion ---
  'legion_protocol_version'           => '2.0',
  'x-legion-region'                   => 'us-east-2',
  'x-legion-identity-canonical-name'  => 'gpu-h100-01',
  'x-legion-identity-id'             => 'node_gpu123',
  'x-legion-identity-kind'           => 'worker',
  'x-legion-identity-mode'           => 'standard',
  'x-legion-identity-source'         => 'dns',

  # --- LLM (from LLM base) ---
  'x-legion-llm-provider'            => 'ollama',
  'x-legion-llm-model'               => 'qwen3.5:27b',
  'x-legion-llm-request-type'        => 'chat',
  'x-legion-llm-schema-version'      => '1.0.0',

  # --- Message context (from LLM base) ---
  'x-legion-llm-conversation-id'     => 'conv_1234567',
  'x-legion-llm-message-id'          => 'msg_005',
  'x-legion-llm-request-id'          => 'req_abc123',

  # --- Tracing (propagated from request, new span for worker leg) ---
  'x-legion-trace-id'                => 'trace_01HZ...',
  'x-legion-span-id'                 => 'span_01HZ...WORKER',
  'x-legion-parent-span-id'          => 'span_01HZ...REQ',
}
```

### JSON Body

```json
{
  "message_context": {
    "conversation_id": "conv_1234567",
    "message_id": "msg_005",
    "parent_message_id": "msg_004",
    "message_seq": 5,
    "request_id": "req_abc123",
    "exchange_id": "exch_001"
  },

  "id": "resp_def456",
  "response_message_id": "msg_006",

  "message": {
    "role": "assistant",
    "content": "The src directory contains: main.rb, config.rb, and utils.rb."
  },

  "routing": {
    "provider": "ollama",
    "model": "qwen3.5:27b",
    "tier": "fleet",
    "strategy": "fleet_dispatch",
    "reason": "fleet_gpu_available",
    "escalated": false,
    "latency_ms": 1245,
    "connection": {
      "endpoint": "http://localhost:11434",
      "reused": true,
      "connect_ms": 0
    }
  },

  "tokens": {
    "input": 42,
    "output": 28,
    "total": 70,
    "thinking": 0,
    "cache_read": 0,
    "cache_create": 0,
    "context_window": 131072,
    "utilization": 0.0005,
    "headroom": 131002
  },

  "thinking": null,

  "stop": {
    "reason": "end_turn",
    "sequence": null
  },

  "tools": [],

  "cost": {
    "estimated_usd": 0.0,
    "provider": "ollama",
    "model": "qwen3.5:27b"
  },

  "quality": {
    "score": 85,
    "band": "good",
    "source": "confidence_scorer"
  },

  "timestamps": {
    "received": "2026-04-08T14:30:00.000Z",
    "provider_start": "2026-04-08T14:30:00.002Z",
    "provider_end": "2026-04-08T14:30:01.245Z",
    "returned": "2026-04-08T14:30:01.247Z"
  },

  "tracing": {
    "trace_id": "trace_01HZ...",
    "span_id": "span_01HZ...WORKER",
    "parent_span_id": "span_01HZ...REQ",
    "correlation_id": null,
    "baggage": {}
  },

  "classification": {
    "level": "internal",
    "contains_pii": false,
    "contains_phi": false,
    "jurisdictions": ["us"],
    "retention": "default"
  },

  "enrichments": {},
  "predictions": {},
  "audit": {
    "fleet:execute": {
      "outcome": "success",
      "detail": "executed on gpu-h100-01 via Ollama",
      "duration_ms": 1245,
      "timestamp": "2026-04-08T14:30:01.247Z"
    }
  },
  "timeline": [],
  "participants": ["legion-llm", "lex-ollama", "ollama"],
  "warnings": [],

  "stream": false,
  "cache": {},
  "retry": null,
  "safety": null,
  "rate_limit": null,
  "features": null,
  "deprecation": null,
  "validation": null,
  "wire": null
}
```

---

## Message 3: Fleet Error (`llm.fleet.error`)

**Who publishes**: Fleet worker (on failure) OR ReplyDispatcher (on basic.return/nack)
**Who consumes**: Requesting node (ReplyDispatcher)
**Exchange**: `''` (default exchange)
**Routing key**: `'llm.fleet.reply.<hex>'`
**Queue**: same as response

### AMQP Properties

| Property | Value | Notes |
|---|---|---|
| `content_type` | `'application/json'` | |
| `content_encoding` | `'identity'` | Errors are never encrypted |
| `type` | `'llm.fleet.error'` | **Different from response** — consumer checks type |
| `message_id` | `'err_<uuid>'` | Unique error ID |
| `correlation_id` | `'req_<uuid>'` | Same as request's correlation_id |
| `reply_to` | nil | |
| `priority` | `0` | |
| `expiration` | nil | |
| `timestamp` | unix epoch | |
| `user_id` | connection user | |
| `app_id` | `'lex-ollama'` or `'legion-llm'` | Worker or requesting node (if self-generated) |

### Headers

```ruby
{
  # --- Standard Legion ---
  'legion_protocol_version'           => '2.0',
  'x-legion-identity-canonical-name'  => 'gpu-h100-01',
  'x-legion-identity-id'             => 'node_gpu123',

  # --- LLM (from LLM base) ---
  'x-legion-llm-provider'            => 'ollama',
  'x-legion-llm-model'               => 'qwen3.5:27b',
  'x-legion-llm-request-type'        => 'chat',

  # --- Message context (from LLM base) ---
  'x-legion-llm-conversation-id'     => 'conv_1234567',
  'x-legion-llm-message-id'          => 'msg_005',
  'x-legion-llm-request-id'          => 'req_abc123',

  # --- Tracing ---
  'x-legion-trace-id'                => 'trace_01HZ...',
  'x-legion-span-id'                 => 'span_01HZ...',

  # --- Error classification (filterable) ---
  'x-legion-fleet-error'             => 'model_not_loaded',
}
```

### JSON Body

```json
{
  "message_context": {
    "conversation_id": "conv_1234567",
    "message_id": "msg_005",
    "parent_message_id": "msg_004",
    "message_seq": 5,
    "request_id": "req_abc123",
    "exchange_id": "exch_001"
  },

  "error": {
    "code": "model_not_loaded",
    "message": "qwen3.5:27b is not available on this Ollama instance",
    "retriable": false,
    "retry_after": null,
    "category": "worker",
    "provider": "ollama"
  },

  "worker_node": "gpu-h100-01",

  "timestamps": {
    "received": "2026-04-08T14:30:00.000Z",
    "returned": "2026-04-08T14:30:00.050Z"
  },

  "enrichments": {},
  "audit": {}
}
```

### Error Codes

| Code | Category | Retriable | When |
|---|---|---|---|
| `model_not_loaded` | `worker` | no | Worker doesn't have the requested model |
| `ollama_unavailable` | `worker` | yes | Ollama HTTP server not responding |
| `inference_failed` | `worker` | yes | Ollama returned HTTP error |
| `inference_timeout` | `worker` | yes | Ollama didn't respond within internal timeout |
| `invalid_token` | `auth` | no | JWT validation failed |
| `token_expired` | `auth` | no | JWT TTL exceeded |
| `payload_too_large` | `validation` | no | Request body exceeds limit |
| `unsupported_type` | `validation` | no | Unknown request_type |
| `no_fleet_queue` | `dispatch` | no | basic.return — no queue matched (self-generated) |
| `fleet_backpressure` | `dispatch` | yes | basic.nack — queue full (self-generated) |
| `fleet_timeout` | `dispatch` | yes | Client timeout — no reply (self-generated) |

The last three (`no_fleet_queue`, `fleet_backpressure`, `fleet_timeout`) are generated
by the **requesting node's** ReplyDispatcher/Dispatcher, not by a worker. They use the
same message format so the Router's error handling is uniform.

---

## Message 4: Metering Event (`llm.metering.event`)

**Who publishes**: Requesting node (legion-llm Metering.emit, after response arrives)
**Who consumes**: DB node (lex-llm-ledger Ledger::Metering::MeteringWriter actor)
**Exchange**: `llm.metering` (topic, durable)
**Routing key**: `metering.<request_type>` (e.g., `metering.chat`, `metering.embed`)
**Queue**: `llm.metering.write` (durable, binds with `metering.#`)

### AMQP Properties

| Property | Value | Notes |
|---|---|---|
| `content_type` | `'application/json'` | |
| `content_encoding` | `'identity'` | Metering is never encrypted (no sensitive content) |
| `type` | `'llm.metering.event'` | |
| `message_id` | `'meter_<uuid>'` | Unique per event |
| `correlation_id` | `'req_<uuid>'` | Links metering event to the fleet request |
| `reply_to` | nil | Fire-and-forget, no reply expected |
| `priority` | `0` | Metering is best-effort |
| `expiration` | nil | Metering should not expire (durable queue) |
| `timestamp` | unix epoch | |
| `user_id` | connection user | |
| `app_id` | `'legion-llm'` | |

### Headers

```ruby
{
  # --- Standard Legion ---
  'legion_protocol_version'           => '2.0',
  'x-legion-region'                   => 'us-east-2',
  'x-legion-identity-canonical-name'  => 'laptop-matt-01',
  'x-legion-identity-id'             => 'node_abc123',

  # --- LLM (from LLM base) ---
  'x-legion-llm-provider'            => 'ollama',
  'x-legion-llm-model'               => 'qwen3.5:27b',
  'x-legion-llm-request-type'        => 'chat',
  'x-legion-llm-schema-version'      => '1.0.0',

  # --- Message context (from LLM base) ---
  'x-legion-llm-conversation-id'     => 'conv_1234567',
  'x-legion-llm-message-id'          => 'msg_005',
  'x-legion-llm-request-id'          => 'req_abc123',

  # --- LLM tier ---
  'x-legion-llm-tier'                => 'fleet',

  # --- Tracing (links to the request trace) ---
  'x-legion-trace-id'                => 'trace_01HZ...',
}
```

### JSON Body

```json
{
  "message_context": {
    "conversation_id": "conv_1234567",
    "message_id": "msg_005",
    "parent_message_id": "msg_004",
    "message_seq": 5,
    "request_id": "req_abc123",
    "exchange_id": "exch_001"
  },

  "node_id": "laptop-matt-01",
  "worker_id": "gpu-h100-01",
  "agent_id": "gaia",
  "task_id": "task_abc123",

  "request_type": "chat",
  "tier": "fleet",
  "provider": "ollama",
  "model_id": "qwen3.5:27b",

  "input_tokens": 42,
  "output_tokens": 28,
  "thinking_tokens": 0,
  "total_tokens": 70,

  "latency_ms": 1245,
  "wall_clock_ms": 1300,

  "cost_usd": 0.0,

  "routing_reason": "fleet_gpu_available",
  "recorded_at": "2026-04-08T14:30:01.300Z",

  "billing": {
    "cost_center": "engineering-platform",
    "budget_id": "budget_q1_2026"
  }
}
```

### Body Field Reference

| Field | Type | Required | Description |
|---|---|---|---|
| `message_context` | hash | yes | Full context struct (see Message Context) |
| `node_id` | string | yes | Requesting node identity |
| `worker_id` | string | no | Worker node identity (nil for local/direct) |
| `agent_id` | string | no | Agent identity (from Request.agent.id) |
| `task_id` | string | no | Higher-level task (from Request.agent.task_id) |
| `request_type` | string | yes | `chat`, `embed`, `generate` |
| `tier` | string | yes | `local`, `fleet`, `direct` |
| `provider` | string | yes | `ollama`, `bedrock`, `anthropic`, etc. |
| `model_id` | string | yes | Model name |
| `input_tokens` | integer | yes | Prompt/input tokens consumed |
| `output_tokens` | integer | yes | Completion/output tokens generated |
| `thinking_tokens` | integer | yes | Extended thinking tokens (0 if none) |
| `total_tokens` | integer | yes | `input + output + thinking` |
| `latency_ms` | integer | yes | Provider call latency (inference time) |
| `wall_clock_ms` | integer | yes | Total wall clock including AMQP round-trip |
| `cost_usd` | float | yes | Estimated cost ($0.0 for self-hosted) |
| `routing_reason` | string | no | Why this tier/provider was selected |
| `recorded_at` | string | yes | ISO 8601 UTC timestamp |
| `billing` | hash | no | Billing context from request (cost_center, budget_id) |

---

## Message 5: Prompt Audit (`llm.audit.prompt`)

**Who publishes**: Requesting node (legion-llm Audit.emit_prompt, after response)
**Who consumes**: DB node (lex-llm-ledger Ledger::Prompts::PromptWriter actor)
**Exchange**: `llm.audit` (topic, durable)
**Routing key**: `audit.prompt.<request_type>` (e.g., `audit.prompt.chat`)
**Queue**: `llm.audit.prompts` (durable, binds with `audit.prompt.#`)

### AMQP Properties

| Property | Value | Notes |
|---|---|---|
| `content_type` | `'application/json'` | |
| `content_encoding` | `'encrypted/cs'` | **Always encrypted** — contains full prompts/responses |
| `type` | `'llm.audit.prompt'` | |
| `message_id` | `'audit_prompt_<uuid>'` | |
| `correlation_id` | `'req_<uuid>'` | Links to fleet request |
| `reply_to` | nil | Fire-and-forget |
| `priority` | `0` | Audit is best-effort |
| `expiration` | nil | Audit records must not expire |
| `timestamp` | unix epoch | |
| `user_id` | connection user | |
| `app_id` | `'legion-llm'` | |

### Headers

```ruby
{
  # --- Standard Legion ---
  'legion_protocol_version'           => '2.0',
  'x-legion-region'                   => 'us-east-2',
  'x-legion-identity-canonical-name'  => 'laptop-matt-01',
  'x-legion-identity-id'             => 'node_abc123',

  # --- LLM (from LLM base) ---
  'x-legion-llm-provider'            => 'ollama',
  'x-legion-llm-model'               => 'qwen3.5:27b',
  'x-legion-llm-request-type'        => 'chat',
  'x-legion-llm-schema-version'      => '1.0.0',

  # --- Message context (from LLM base) ---
  'x-legion-llm-conversation-id'     => 'conv_1234567',
  'x-legion-llm-message-id'          => 'msg_005',
  'x-legion-llm-request-id'          => 'req_abc123',

  # --- LLM tier ---
  'x-legion-llm-tier'                => 'fleet',

  # --- Tracing ---
  'x-legion-trace-id'                => 'trace_01HZ...',
  'x-legion-span-id'                 => 'span_01HZ...',

  # --- Classification (for compliance filtering without decrypting body) ---
  'x-legion-classification'          => 'internal',
  'x-legion-contains-phi'            => 'false',
  'x-legion-jurisdictions'           => 'us',

  # --- Caller identity (for RBAC/audit without decrypting body) ---
  'x-legion-caller-identity'         => 'user:matt',
  'x-legion-caller-type'             => 'user',

  # --- Retention (so ledger knows TTL without decrypting) ---
  'x-legion-retention'               => 'default',
}
```

### JSON Body (encrypted)

The body is encrypted via `Legion::Crypt` (`content_encoding: 'encrypted/cs'`).
After decryption:

```json
{
  "message_context": {
    "conversation_id": "conv_1234567",
    "message_id": "msg_005",
    "parent_message_id": "msg_004",
    "message_seq": 5,
    "request_id": "req_abc123",
    "exchange_id": "exch_005"
  },

  "response_message_id": "msg_006",

  "request": {
    "system": "You are a helpful assistant.",
    "messages": [
      { "role": "user", "content": "What files are in the src directory?" }
    ],
    "tools": [
      { "name": "list_files", "description": "List files in a directory" }
    ],
    "generation": { "temperature": 0.7 },
    "stream": false,
    "context_strategy": "auto"
  },

  "response": {
    "message": {
      "role": "assistant",
      "content": "The src directory contains: main.rb, config.rb, and utils.rb."
    },
    "tools": [],
    "stop": { "reason": "end_turn" }
  },

  "routing": {
    "provider": "ollama",
    "model": "qwen3.5:27b",
    "tier": "fleet",
    "strategy": "fleet_dispatch",
    "escalated": false,
    "latency_ms": 1245
  },

  "tokens": {
    "input": 42,
    "output": 28,
    "total": 70,
    "thinking": 0
  },

  "cost": {
    "estimated_usd": 0.0,
    "provider": "ollama",
    "model": "qwen3.5:27b"
  },

  "caller": {
    "requested_by": {
      "identity": "user:matt",
      "type": "user",
      "credential": "session"
    }
  },
  "agent": {
    "id": "gaia",
    "name": "GAIA",
    "type": "autonomous",
    "task_id": "task_abc123"
  },

  "classification": {
    "level": "internal",
    "contains_pii": false,
    "contains_phi": false,
    "jurisdictions": ["us"],
    "retention": "default"
  },

  "billing": {
    "cost_center": "engineering-platform",
    "budget_id": "budget_q1_2026"
  },

  "timestamps": {
    "received": "2026-04-08T14:30:00.000Z",
    "provider_start": "2026-04-08T14:30:00.002Z",
    "provider_end": "2026-04-08T14:30:01.245Z",
    "returned": "2026-04-08T14:30:01.247Z"
  },

  "quality": {
    "score": 85,
    "band": "good",
    "source": "confidence_scorer"
  },

  "audit": {
    "fleet:execute": {
      "outcome": "success",
      "detail": "executed on gpu-h100-01 via Ollama",
      "duration_ms": 1245
    }
  },

  "tracing": {
    "trace_id": "trace_01HZ...",
    "span_id": "span_01HZ...",
    "parent_span_id": null,
    "correlation_id": null,
    "baggage": {}
  }
}
```

### Why encrypted

Prompt audit contains full conversation content — potentially PHI, PII, confidential code,
user messages. Even on internal AMQP, this must be encrypted at rest and in transit.
Classification headers are in cleartext so compliance middleware can route/filter without
decrypting. The content itself is only readable by nodes with `Legion::Crypt` keys.

### Retention

The `x-legion-retention` header tells lex-llm-ledger how long to keep this record:

| Value | Behavior |
|---|---|
| `default` | 90 days (configurable) |
| `session_only` | Delete when conversation ends |
| `days_30` | 30-day TTL |
| `days_90` | 90-day TTL |
| `permanent` | Never auto-delete |

PHI-flagged records (`x-legion-contains-phi: true`) are capped at the PHI TTL
regardless of requested retention (HIPAA compliance).

---

## Message 6: Tool Audit (`llm.audit.tool`)

**Who publishes**: Requesting node (legion-llm Audit.emit_tools, after tool execution)
**Who consumes**: DB node (lex-llm-ledger Ledger::Tools::ToolWriter actor)
**Exchange**: `llm.audit` (topic, durable)
**Routing key**: `audit.tool.<tool_name>` (e.g., `audit.tool.list_files`)
**Queue**: `llm.audit.tools` (durable, binds with `audit.tool.#`)

### AMQP Properties

| Property | Value | Notes |
|---|---|---|
| `content_type` | `'application/json'` | |
| `content_encoding` | `'encrypted/cs'` | **Always encrypted** — contains tool args/results |
| `type` | `'llm.audit.tool'` | |
| `message_id` | `'audit_tool_<uuid>'` | |
| `correlation_id` | `'req_<uuid>'` | Links to parent fleet request |
| `reply_to` | nil | |
| `priority` | `0` | |
| `expiration` | nil | |
| `timestamp` | unix epoch | |
| `user_id` | connection user | |
| `app_id` | `'legion-llm'` | |

### Headers

```ruby
{
  # --- Standard Legion ---
  'legion_protocol_version'           => '2.0',
  'x-legion-region'                   => 'us-east-2',
  'x-legion-identity-canonical-name'  => 'laptop-matt-01',
  'x-legion-identity-id'             => 'node_abc123',

  # --- LLM (from LLM base) ---
  'x-legion-llm-provider'            => 'ollama',
  'x-legion-llm-model'               => 'qwen3.5:27b',
  'x-legion-llm-request-type'        => 'chat',
  'x-legion-llm-schema-version'      => '1.0.0',

  # --- Message context (from LLM base) ---
  'x-legion-llm-conversation-id'     => 'conv_1234567',
  'x-legion-llm-message-id'          => 'msg_005',
  'x-legion-llm-request-id'          => 'req_abc123',

  # --- Tracing ---
  'x-legion-trace-id'                => 'trace_01HZ...',
  'x-legion-span-id'                 => 'span_01HZ...',
  'x-legion-parent-span-id'          => 'span_01HZ...',

  # --- Tool metadata (filterable without decrypting) ---
  'x-legion-tool-name'               => 'list_files',
  'x-legion-tool-source-type'        => 'mcp',
  'x-legion-tool-source-server'      => 'filesystem',
  'x-legion-tool-status'             => 'success',

  # --- Classification ---
  'x-legion-classification'          => 'internal',
  'x-legion-contains-phi'            => 'false',
}
```

### JSON Body (encrypted)

```json
{
  "message_context": {
    "conversation_id": "conv_1234567",
    "message_id": "msg_005",
    "parent_message_id": "msg_004",
    "message_seq": 5,
    "request_id": "req_abc123",
    "exchange_id": "exch_004"
  },

  "tool_call": {
    "id": "tc_def456",
    "name": "list_files",
    "arguments": {
      "path": "/src"
    },
    "source": {
      "type": "mcp",
      "server": "filesystem"
    },
    "status": "success",
    "duration_ms": 45,
    "result": "main.rb\nconfig.rb\nutils.rb",
    "error": null
  },

  "caller": {
    "requested_by": {
      "identity": "user:matt",
      "type": "user"
    }
  },
  "agent": {
    "id": "gaia",
    "name": "GAIA",
    "type": "autonomous"
  },

  "timestamps": {
    "tool_start": "2026-04-08T14:30:01.260Z",
    "tool_end": "2026-04-08T14:30:01.305Z"
  }
}
```

---

## Summary: All Six Messages at a Glance

```
┌──────────────────────┬──────────────────────┬───────────────────┬────────────────────┐
│ Message              │ type property        │ Exchange          │ Routing Key        │
├──────────────────────┼──────────────────────┼───────────────────┼────────────────────┤
│ Fleet Request        │ llm.fleet.request    │ llm.request       │ llm.request.       │
│                      │                      │ (topic)           │   <prov>.<type>.   │
│                      │                      │                   │   <model>          │
├──────────────────────┼──────────────────────┼───────────────────┼────────────────────┤
│ Fleet Response       │ llm.fleet.response   │ '' (default)      │ llm.fleet.reply.   │
│                      │                      │                   │   <hex>            │
├──────────────────────┼──────────────────────┼───────────────────┼────────────────────┤
│ Fleet Error          │ llm.fleet.error      │ '' (default)      │ llm.fleet.reply.   │
│                      │                      │                   │   <hex>            │
├──────────────────────┼──────────────────────┼───────────────────┼────────────────────┤
│ Metering Event       │ llm.metering.event   │ llm.metering      │ metering.<type>    │
│                      │                      │ (topic)           │                    │
├──────────────────────┼──────────────────────┼───────────────────┼────────────────────┤
│ Prompt Audit         │ llm.audit.prompt     │ llm.audit         │ audit.prompt.      │
│                      │                      │ (topic)           │   <type>           │
├──────────────────────┼──────────────────────┼───────────────────┼────────────────────┤
│ Tool Audit           │ llm.audit.tool       │ llm.audit         │ audit.tool.        │
│                      │                      │ (topic)           │   <tool_name>      │
└──────────────────────┴──────────────────────┴───────────────────┴────────────────────┘
```

### Property Usage Across Message Types

```
                        Request   Response  Error     Metering  Prompt    Tool
                        ───────   ────────  ─────     ────────  ──────    ────
content_type            json      json      json      json      json      json
content_encoding        id/enc    id/enc    identity  identity  encrypted encrypted
type                    .request  .response .error    .event    .prompt   .tool
message_id              req_*     resp_*    err_*     meter_*   audit_p_* audit_t_*
correlation_id          req_*     req_*     req_*     req_*     req_*     req_*
reply_to                reply_q   nil       nil       nil       nil       nil
priority                0-9       0         0         0         0         0
expiration              ttl→ms    nil       nil       nil       nil       nil
timestamp               auto      auto      auto      auto      auto      auto
user_id                 conn      conn      conn      conn      conn      conn
app_id                  l-llm     lex-*     lex-*/llm l-llm     l-llm     l-llm
```

### Header Usage Across Message Types

```
                                  Request  Response  Error  Metering  Prompt  Tool
                                  ───────  ────────  ─────  ────────  ──────  ────
legion_protocol_version           yes      yes       yes    yes       yes     yes
x-legion-region                   yes      yes       yes    yes       yes     yes
x-legion-identity-*               yes      yes       yes    yes       yes     yes
x-legion-llm-provider             yes      yes       yes    yes       yes     yes
x-legion-llm-model                yes      yes       yes    yes       yes     yes
x-legion-llm-request-type         yes      yes       yes    yes       yes     yes
x-legion-llm-schema-version       yes      yes       —      yes       yes     yes
x-legion-llm-conversation-id      yes      yes       yes    yes       yes     yes
x-legion-llm-message-id           yes      yes       yes    yes       yes     yes
x-legion-llm-request-id           yes      yes       yes    yes       yes     yes
x-legion-llm-tier                 yes      —         —      yes       yes     —
x-legion-trace-id                 yes      yes       yes    yes       yes     yes
x-legion-span-id                  yes      yes       yes    —         yes     yes
x-legion-parent-span-id           yes      yes       —      —         —       yes
x-legion-trace-correlation-id     yes      —         —      —         —       —
x-legion-classification           yes      —         —      —         yes     yes
x-legion-contains-phi             yes      —         —      —         yes     yes
x-legion-jurisdictions            yes      —         —      —         yes     —
x-legion-fleet-token              yes      —         —      —         —       —
x-legion-fleet-error              —        —         yes    —         —       —
x-legion-caller-identity          —        —         —      —         yes     —
x-legion-retention                —        —         —      —         yes     —
x-legion-tool-name                —        —         —      —         —       yes
x-legion-tool-source-type         —        —         —      —         —       yes
x-legion-tool-status              —        —         —      —         —       yes
```

### message_context in Body (All Six)

```
                        Request   Response  Error     Metering  Prompt    Tool
                        ───────   ────────  ─────     ────────  ──────    ────
conversation_id         yes       yes       yes       yes       yes       yes
message_id              yes       yes       yes       yes       yes       yes
parent_message_id       yes       yes       yes       yes       yes       yes
message_seq             yes       yes       yes       yes       yes       yes
request_id              yes       yes       yes       yes       yes       yes
exchange_id             yes       yes       yes       yes       yes       yes
```

---

## Implementation: Message Classes

### Legion::LLM::Transport::Message (LLM Base)

```ruby
module Legion
  module LLM
    module Transport
      class Message < ::Legion::Transport::Message
        LLM_ENVELOPE_KEYS = %i[
          message_context routing_key reply_to fleet_correlation_id
          request_type provider model priority ttl
        ].freeze

        def message_context
          @options[:message_context] || {}
        end

        def message
          @options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)
        end

        def message_id
          @options[:message_id] || "#{message_id_prefix}_#{SecureRandom.uuid}"
        end

        def correlation_id
          @options[:fleet_correlation_id] || super
        end

        def app_id
          @options[:app_id] || 'legion-llm'
        end

        def headers
          super.merge(llm_headers).merge(context_headers)
        end

        private

        def message_id_prefix = 'msg'

        def llm_headers
          h = {}
          h['x-legion-llm-provider']       = @options[:provider].to_s     if @options[:provider]
          h['x-legion-llm-model']          = @options[:model].to_s        if @options[:model]
          h['x-legion-llm-request-type']   = @options[:request_type].to_s if @options[:request_type]
          h['x-legion-llm-schema-version'] = '1.0.0'
          h
        end

        def context_headers
          ctx = message_context
          h = {}
          h['x-legion-llm-conversation-id'] = ctx[:conversation_id].to_s if ctx[:conversation_id]
          h['x-legion-llm-message-id']      = ctx[:message_id].to_s      if ctx[:message_id]
          h['x-legion-llm-request-id']      = ctx[:request_id].to_s      if ctx[:request_id]
          h
        end
      end
    end
  end
end
```

### Fleet Messages

```ruby
module Legion
  module LLM
    module Fleet
      class Request < Legion::LLM::Transport::Message
        PRIORITY_MAP = { critical: 9, high: 7, normal: 5, low: 2 }.freeze

        def type           = 'llm.fleet.request'
        def exchange       = Legion::LLM::Fleet::Exchange
        def routing_key    = @options[:routing_key]
        def reply_to       = @options[:reply_to]
        def priority       = map_priority(@options[:priority])
        def expiration     = @options[:ttl] ? (@options[:ttl] * 1000).to_s : super

        private

        def message_id_prefix = 'req'

        def map_priority(val)
          return val if val.is_a?(Integer)
          PRIORITY_MAP.fetch(val, 5)
        end
      end

      class Response < Legion::LLM::Transport::Message
        def type           = 'llm.fleet.response'
        def exchange       = nil  # default exchange
        def routing_key    = @options[:reply_to]
        def priority       = 0
        def app_id         = @options[:app_id] || 'lex-ollama'

        def headers
          super.merge(tracing_headers)
        end

        private

        def message_id_prefix = 'resp'
      end

      class Error < Legion::LLM::Transport::Message
        def type           = 'llm.fleet.error'
        def exchange       = nil
        def routing_key    = @options[:reply_to]
        def priority       = 0
        def encrypt?       = false

        def headers
          super.merge(error_headers)
        end

        private

        def message_id_prefix = 'err'

        def error_headers
          h = {}
          code = @options.dig(:error, :code)
          h['x-legion-fleet-error'] = code.to_s if code
          h
        end
      end
    end

    module Metering
      class Event < Legion::LLM::Transport::Message
        def type           = 'llm.metering.event'
        def exchange       = Legion::LLM::Metering::Exchange
        def routing_key    = "metering.#{@options[:request_type]}"
        def priority       = 0
        def encrypt?       = false

        def headers
          super.merge(tier_header)
        end

        private

        def message_id_prefix = 'meter'

        def tier_header
          h = {}
          h['x-legion-llm-tier'] = @options[:tier].to_s if @options[:tier]
          h
        end
      end
    end

    module Audit
      class PromptEvent < Legion::LLM::Transport::Message
        def type           = 'llm.audit.prompt'
        def exchange       = Legion::LLM::Audit::Exchange
        def routing_key    = "audit.prompt.#{@options[:request_type]}"
        def priority       = 0
        def encrypt?       = true

        def headers
          super.merge(classification_headers, caller_headers, retention_headers, tier_header)
        end

        private

        def message_id_prefix = 'audit_prompt'

        def classification_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-classification'] = cls[:level].to_s   if cls[:level]
          h['x-legion-contains-phi']   = cls[:contains_phi].to_s unless cls[:contains_phi].nil?
          h['x-legion-jurisdictions']  = Array(cls[:jurisdictions]).join(',') if cls[:jurisdictions]
          h
        end

        def caller_headers
          caller = @options.dig(:caller, :requested_by) || {}
          h = {}
          h['x-legion-caller-identity'] = caller[:identity].to_s if caller[:identity]
          h['x-legion-caller-type']     = caller[:type].to_s     if caller[:type]
          h
        end

        def retention_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-retention'] = cls[:retention].to_s if cls[:retention]
          h
        end

        def tier_header
          h = {}
          h['x-legion-llm-tier'] = @options[:tier].to_s if @options[:tier]
          h
        end
      end

      class ToolEvent < Legion::LLM::Transport::Message
        def type           = 'llm.audit.tool'
        def exchange       = Legion::LLM::Audit::Exchange
        def routing_key    = "audit.tool.#{@options[:tool_name]}"
        def priority       = 0
        def encrypt?       = true

        def headers
          super.merge(tool_headers, classification_headers)
        end

        private

        def message_id_prefix = 'audit_tool'

        def tool_headers
          tc = @options[:tool_call] || {}
          src = tc[:source] || {}
          h = {}
          h['x-legion-tool-name']        = tc[:name].to_s        if tc[:name]
          h['x-legion-tool-source-type'] = src[:type].to_s       if src[:type]
          h['x-legion-tool-source-server'] = src[:server].to_s   if src[:server]
          h['x-legion-tool-status']      = tc[:status].to_s      if tc[:status]
          h
        end

        def classification_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-classification'] = cls[:level].to_s   if cls[:level]
          h['x-legion-contains-phi']   = cls[:contains_phi].to_s unless cls[:contains_phi].nil?
          h
        end
      end
    end
  end
end
```

All six message classes follow the same pattern: inherit `Legion::LLM::Transport::Message`,
override property methods, merge domain-specific headers via `super.merge(...)`, let
`#message` strip envelope keys from the body. `message_context` is always present in the
body and the context subset is always in headers — handled by the LLM base class.

# Fleet LLM Implementation Plan: legion-llm

**Date**: 2026-04-08
**Author**: Matthew Iverson (@Esity)
**Status**: Ready for Implementation
**Scope**: legion-llm core library only (Day-0 prerequisite)
**Related**:
- [Fleet Architecture Design](2026-04-08-fleet-llm-architecture-design.md)
- [Fleet Wire Protocol](2026-04-08-fleet-wire-protocol.md)
- [Fleet Queue Subscription Design](2026-04-07-fleet-queue-subscription-design.md)

---

## Overview

### What This Delivers

This plan covers all changes to `legion-llm` required before lex-ollama fleet workers can
be tested end-to-end. Every fleet message class, exchange declaration, metering emission
module, and audit emission module lives here. lex-ollama, lex-bedrock, and future provider
fleet workers depend on these classes — none of them can publish or consume typed fleet
messages without this work in place.

**Day-0 deliverables (this plan):**

1. `Legion::LLM::Transport::Message` — LLM base message class with `message_context` propagation and LLM-specific headers
2. `Legion::LLM::Fleet::Exchange` — declares the `llm.request` topic exchange (source of truth)
3. `Legion::LLM::Fleet::Request` — fleet inference request message
4. `Legion::LLM::Fleet::Response` — fleet inference response message
5. `Legion::LLM::Fleet::Error` — fleet error message
6. `Legion::LLM::Metering::Exchange` — declares the `llm.metering` topic exchange
7. `Legion::LLM::Metering::Event` — metering event message
8. `Legion::LLM::Metering` module — `emit`, `flush_spool` public API
9. `Legion::LLM::Audit::Exchange` — declares the `llm.audit` topic exchange
10. `Legion::LLM::Audit::PromptEvent` — prompt audit message (always encrypted)
11. `Legion::LLM::Audit::ToolEvent` — tool call audit message (always encrypted)
12. `Legion::LLM::Audit` module — `emit_prompt`, `emit_tools` public API
13. Update `Fleet::Dispatcher` — use `Fleet::Request` message class, `mandatory: true`, publisher confirms, `basic.return` handling, per-type timeouts
14. Update `Fleet::ReplyDispatcher` — add `basic.nack` handler, reply queue uses `Fleet::Response`/`Fleet::Error` type dispatch
15. Update `Pipeline::Steps::Metering` — use `Metering::Event` instead of `Gateway::Transport::Messages::MeteringEvent`
16. Update `Pipeline::AuditPublisher` — use `Audit::PromptEvent` instead of `AuditEvent`
17. Update settings — add `fleet.tier_priority`, per-type timeouts, `consumer_priority`

### Dependencies

**legion-llm depends on:**
- `legion-transport` >= any current version — provides `Legion::Transport::Message` and `Legion::Transport::Exchange` base classes
- `concurrent-ruby` — already present for `ReplyDispatcher`

**lex-ollama depends on legion-llm for:**
- `Legion::LLM::Fleet::Exchange` — exchange name/type reference
- `Legion::LLM::Fleet::Response` — response message class (workers subclass or instantiate)
- `Legion::LLM::Fleet::Error` — error message class
- `Legion::LLM::Transport::Message` — LLM message base

**Nothing in this plan requires lex-ollama to be present.** legion-llm compiles and tests
independently.

### What This Does NOT Cover

- lex-ollama `Transport::Queues::ModelRequest`, `Transport::Messages::LlmResponse`, `Runners::Fleet`, `Actor::ModelWorker` — those are in the lex-ollama implementation plan
- lex-llm-ledger (new extension) — `MeteringWriter`, `PromptWriter`, `ToolWriter` actors — separate plan
- lex-llm-gateway decomposition — covered in its own plan; this plan is additive (new files + targeted modifications)

---

## File Inventory

### New Files to Create

| File | Class/Module | Responsibility |
|------|--------------|----------------|
| `lib/legion/llm/transport/message.rb` | `Legion::LLM::Transport::Message` | LLM base message class: `message_context` propagation, LLM headers, envelope key stripping |
| `lib/legion/llm/fleet/exchange.rb` | `Legion::LLM::Fleet::Exchange` | Declares `llm.request` topic exchange (durable) |
| `lib/legion/llm/fleet/request.rb` | `Legion::LLM::Fleet::Request` | Fleet inference request: type `llm.fleet.request`, priority mapping, ttl→expiration |
| `lib/legion/llm/fleet/response.rb` | `Legion::LLM::Fleet::Response` | Fleet response: type `llm.fleet.response`, default exchange publish |
| `lib/legion/llm/fleet/error.rb` | `Legion::LLM::Fleet::Error` | Fleet error: type `llm.fleet.error`, error code header, default exchange publish |
| `lib/legion/llm/metering/exchange.rb` | `Legion::LLM::Metering::Exchange` | Declares `llm.metering` topic exchange (durable) |
| `lib/legion/llm/metering/event.rb` | `Legion::LLM::Metering::Event` | Metering event: type `llm.metering.event`, routing key `metering.<request_type>` |
| `lib/legion/llm/metering.rb` | `Legion::LLM::Metering` | `emit(event_hash)`, `flush_spool` — replaces `Steps::Metering.publish_or_spool` as the canonical public API |
| `lib/legion/llm/audit/exchange.rb` | `Legion::LLM::Audit::Exchange` | Declares `llm.audit` topic exchange (durable) |
| `lib/legion/llm/audit/prompt_event.rb` | `Legion::LLM::Audit::PromptEvent` | Prompt audit: type `llm.audit.prompt`, always encrypted, classification/caller/retention headers |
| `lib/legion/llm/audit/tool_event.rb` | `Legion::LLM::Audit::ToolEvent` | Tool audit: type `llm.audit.tool`, always encrypted, tool/classification headers |
| `lib/legion/llm/audit.rb` | `Legion::LLM::Audit` | `emit_prompt(event_hash)`, `emit_tools(event_hash)` |
| `spec/legion/llm/transport/message_spec.rb` | — | Tests for LLM base message class |
| `spec/legion/llm/fleet/exchange_spec.rb` | — | Tests for fleet exchange declaration |
| `spec/legion/llm/fleet/request_spec.rb` | — | Tests for Fleet::Request message |
| `spec/legion/llm/fleet/response_spec.rb` | — | Tests for Fleet::Response message |
| `spec/legion/llm/fleet/error_spec.rb` | — | Tests for Fleet::Error message |
| `spec/legion/llm/metering/exchange_spec.rb` | — | Tests for metering exchange |
| `spec/legion/llm/metering/event_spec.rb` | — | Tests for Metering::Event message |
| `spec/legion/llm/metering_spec.rb` | — | Tests for Metering emit/spool API |
| `spec/legion/llm/audit/exchange_spec.rb` | — | Tests for audit exchange |
| `spec/legion/llm/audit/prompt_event_spec.rb` | — | Tests for Audit::PromptEvent |
| `spec/legion/llm/audit/tool_event_spec.rb` | — | Tests for Audit::ToolEvent |
| `spec/legion/llm/audit_spec.rb` | — | Tests for Audit emit API |

### Existing Files to Modify

| File | Change | Why |
|------|--------|-----|
| `lib/legion/llm/fleet.rb` | Add `require` for new `exchange`, `request`, `response`, `error` files | New files must be loaded |
| `lib/legion/llm/fleet/dispatcher.rb` | Replace `InferenceRequest` with `Fleet::Request`; add `mandatory: true`; add `on_return` handler; add `confirm_select`; add per-type timeout resolution; add `message_context` and `routing_key` building | Core dispatch upgrade |
| `lib/legion/llm/fleet/reply_dispatcher.rb` | Add `on_nack` handler for `fleet_backpressure`; add `message type` dispatch (response vs error); type-check delivery body for `Fleet::Response`/`Fleet::Error` | Support new feedback channels |
| `lib/legion/llm/pipeline/steps/metering.rb` | Change `publish_event` to call `Legion::LLM::Metering.emit` instead of `Gateway::Transport::Messages::MeteringEvent` | Remove gateway dependency |
| `lib/legion/llm/pipeline/audit_publisher.rb` | Change `publish` to call `Legion::LLM::Audit.emit_prompt` instead of `AuditEvent`; pass `message_context` in event | Remove gateway dependency; add context |
| `lib/legion/llm/settings.rb` | Add `fleet.tier_priority`, `fleet.timeouts` (embed/chat/generate/default), `fleet.consumer_priority` under routing defaults | New config keys |
| `lib/legion/llm.rb` | Add `require` for `metering` and `audit` modules | New top-level modules |

---

## Implementation Order

Dependencies flow strictly downward. Do not start a step until all items it depends on
are complete and passing specs.

```
Step 1: Legion::LLM::Transport::Message
  (no dependencies other than Legion::Transport::Message from legion-transport)

Step 2: Exchange declarations (parallel — no interdependencies)
  2a. Legion::LLM::Fleet::Exchange
  2b. Legion::LLM::Metering::Exchange
  2c. Legion::LLM::Audit::Exchange

Step 3: Message classes (depend on Step 1 + respective exchange from Step 2)
  3a. Legion::LLM::Fleet::Request    (depends on 1, 2a)
  3b. Legion::LLM::Fleet::Response   (depends on 1, 2a)
  3c. Legion::LLM::Fleet::Error      (depends on 1, 2a)
  3d. Legion::LLM::Metering::Event   (depends on 1, 2b)
  3e. Legion::LLM::Audit::PromptEvent (depends on 1, 2c)
  3f. Legion::LLM::Audit::ToolEvent  (depends on 1, 2c)

Step 4: Top-level module APIs (depend on their respective message classes from Step 3)
  4a. Legion::LLM::Metering          (depends on 3d)
  4b. Legion::LLM::Audit             (depends on 3e, 3f)

Step 5: Update fleet.rb loader (depends on 2a, 3a, 3b, 3c)

Step 6: Update Fleet::Dispatcher     (depends on 3a, step 5)
Step 7: Update Fleet::ReplyDispatcher (depends on 3b, 3c, step 5)

Step 8: Update Pipeline::Steps::Metering  (depends on 4a)
Step 9: Update Pipeline::AuditPublisher   (depends on 4b)

Step 10: Update Settings (independent, but must be done before integration tests)
Step 11: Update lib/legion/llm.rb requires (depends on all of above)
```

---

## Class Specifications

### `Legion::LLM::Transport::Message`

**File**: `lib/legion/llm/transport/message.rb`

This is the LLM-specific base message class. All six fleet message types inherit from it.
It does not exist yet. The wire protocol document contains the exact implementation.

```ruby
class Legion::LLM::Transport::Message < ::Legion::Transport::Message
```

**Constants:**

```ruby
LLM_ENVELOPE_KEYS = %i[
  fleet_correlation_id provider model ttl
].freeze
```

These keys are stripped from the JSON body (in addition to the base class's `ENVELOPE_KEYS`).
Do NOT add `:request_type` here — metering and audit need it in the body.
Do NOT add `:message_context` — it MUST appear in the body of all 6 messages.
Do NOT add `:priority` — already in the base class's `ENVELOPE_KEYS`.

**Public instance methods:**

| Method | Signature | Return | Behavior |
|--------|-----------|--------|----------|
| `message_context` | `()` | `Hash` | `@options[:message_context] \|\| {}` |
| `message` | `()` | `Hash` | `@options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)` — the JSON body payload |
| `message_id` | `()` | `String` | `@options[:message_id] \|\| "#{message_id_prefix}_#{SecureRandom.uuid}"` |
| `correlation_id` | `()` | `String, nil` | `@options[:fleet_correlation_id] \|\| super` — uses `:fleet_correlation_id` to avoid collision with base class `:correlation_id` behavior (which reads `:parent_id`/`:task_id`) |
| `app_id` | `()` | `String` | `@options[:app_id] \|\| 'legion-llm'` |
| `headers` | `()` | `Hash` | `super.merge(llm_headers).merge(context_headers)` |
| `tracing_headers` | `()` | `Hash` | `{}` — stub for future OpenTelemetry integration; subclasses override |

**Private methods:**

| Method | Signature | Return | Behavior |
|--------|-----------|--------|----------|
| `message_id_prefix` | `()` | `String` | `'msg'` — subclasses override to set their prefix |
| `llm_headers` | `()` | `Hash` | Builds `x-legion-llm-*` headers from `@options[:provider]`, `@options[:model]`, `@options[:request_type]`; always includes `x-legion-llm-schema-version: '1.0.0'` |
| `context_headers` | `()` | `Hash` | Promotes `message_context[:conversation_id]`, `[:message_id]`, `[:request_id]` to `x-legion-llm-conversation-id`, `x-legion-llm-message-id`, `x-legion-llm-request-id` headers; only present if non-nil |

**Notes:**
- `message_context` keys are accessed as symbols — callers must pass `message_context:` as a symbol-keyed hash
- `tracing_headers` returns `{}` always in v1; the wire protocol reserves header slots (`x-legion-trace-id`, etc.) for future OTel integration
- Header keys listed in wire protocol doc section "LLM Headers" must match exactly

---

### `Legion::LLM::Fleet::Exchange`

**File**: `lib/legion/llm/fleet/exchange.rb`

Declares the `llm.request` topic exchange. This is the single source of truth for the
exchange name. lex-ollama's `Transport::Exchanges::LlmRequest` references this class
rather than hard-coding the exchange name.

```ruby
class Legion::LLM::Fleet::Exchange < ::Legion::Transport::Exchange
  def exchange_name = 'llm.request'
  def default_type  = 'topic'
end
```

**Note**: `Legion::Transport::Exchange` does NOT have class-level DSL methods. All existing
exchanges use instance method overrides (`def exchange_name`, `def default_type`).

Exchange is durable. Auto-delete is false (the exchange persists; queues are auto-delete).

---

### `Legion::LLM::Fleet::Request`

**File**: `lib/legion/llm/fleet/request.rb`

Fleet inference request. Published by `Fleet::Dispatcher` to the `llm.request` exchange.

```ruby
class Legion::LLM::Fleet::Request < Legion::LLM::Transport::Message
```

**Constants:**

```ruby
PRIORITY_MAP = { critical: 9, high: 7, normal: 5, low: 2 }.freeze
```

**AMQP property methods:**

| Method | Return | Value |
|--------|--------|-------|
| `type` | `String` | `'llm.fleet.request'` |
| `exchange` | Class | `Legion::LLM::Fleet::Exchange` |
| `routing_key` | `String` | `@options[:routing_key]` — caller must set this; format: `llm.request.<provider>.<type>.<model>` |
| `reply_to` | `String` | `@options[:reply_to]` — the requesting process's reply queue name |
| `priority` | `Integer` | `map_priority(@options[:priority])` — maps symbol to int via `PRIORITY_MAP`; falls back to `5` (normal) |
| `expiration` | `String, nil` | `@options[:ttl] ? (@options[:ttl] * 1000).to_s : super` — converts TTL seconds to milliseconds string |

**Private methods:**

| Method | Return | Behavior |
|--------|--------|----------|
| `message_id_prefix` | `String` | `'req'` — produces `req_<uuid>` message IDs |
| `map_priority(val)` | `Integer` | `return val if val.is_a?(Integer)`; `PRIORITY_MAP.fetch(val, 5)` for symbols |

**JSON body**: the full fleet request body from the wire protocol — system, messages, tools,
generation, thinking, response_format, stream, tokens, stop, context_strategy, cache, fork,
extra, metadata, enrichments, predictions, tracing, classification, caller, agent, billing,
test, hooks, modality, routing, message_context. All envelope keys are stripped from body
by the base class `#message` method.

**Caller responsibility**: The caller (`Fleet::Dispatcher`) must:
1. Set `routing_key:` to the sanitized routing key string
2. Set `reply_to:` to `ReplyDispatcher.agent_queue_name`
3. Set `fleet_correlation_id:` to the same value as `message_id` (for RPC round-trip)
4. Pass `message_context:` as a symbol-keyed hash
5. Pass `provider:`, `model:`, `request_type:` for header injection

---

### `Legion::LLM::Fleet::Response`

**File**: `lib/legion/llm/fleet/response.rb`

Fleet inference response. Published by fleet workers (lex-ollama, lex-bedrock, etc.)
to the AMQP default exchange, routing to the requesting node's reply queue.

```ruby
class Legion::LLM::Fleet::Response < Legion::LLM::Transport::Message
```

**AMQP property methods:**

| Method | Return | Value |
|--------|--------|-------|
| `type` | `String` | `'llm.fleet.response'` |
| `routing_key` | `String` | `@options[:reply_to]` — the reply queue name copied from the request |
| `priority` | `Integer` | `0` — replies don't need queue ordering |
| `expiration` | `nil` | Replies should be consumed immediately; no TTL |

**Override `#publish`**: This class overrides `#publish` to use `channel.default_exchange`
instead of a named exchange. The base class's `#publish` calls `exchange.publish(...)` but
the AMQP default exchange is accessed differently in Bunny.

```ruby
def publish(options = @options)
  raise unless @valid

  channel.default_exchange.publish(
    encode_message,
    routing_key:      routing_key,
    content_type:     options[:content_type] || content_type,
    content_encoding: options[:content_encoding] || content_encoding,
    type:             type,
    priority:         priority,
    message_id:       message_id,
    correlation_id:   correlation_id,
    timestamp:        timestamp
  )
end
```

**Private methods:**

| Method | Return | Behavior |
|--------|--------|----------|
| `message_id_prefix` | `String` | `'resp'` — produces `resp_<uuid>` message IDs |

**Worker responsibility**: Fleet workers (lex-ollama, lex-bedrock) instantiate this class
with `app_id:` set to their gem name (e.g., `'lex-ollama'`). The class itself does NOT
hardcode a provider name.

**JSON body**: message_context (copied verbatim from request), response message, routing
(provider, model, tier, latency_ms, etc.), tokens, thinking, stop, tools, cost, quality,
timestamps, tracing, classification, enrichments, predictions, audit, timeline,
participants, warnings, stream, cache, retry, safety, rate_limit, features, deprecation,
validation, wire. The `id` and `response_message_id` fields are also in the body.

---

### `Legion::LLM::Fleet::Error`

**File**: `lib/legion/llm/fleet/error.rb`

Fleet error response. Published by fleet workers on failure OR by the requesting node's
`ReplyDispatcher` for transport-level failures (`no_fleet_queue`, `fleet_backpressure`,
`fleet_timeout`).

```ruby
class Legion::LLM::Fleet::Error < Legion::LLM::Transport::Message
```

**AMQP property methods:**

| Method | Return | Value |
|--------|--------|-------|
| `type` | `String` | `'llm.fleet.error'` |
| `routing_key` | `String` | `@options[:reply_to]` |
| `priority` | `Integer` | `0` |
| `expiration` | `nil` | No TTL |
| `encrypt?` | `Boolean` | `false` — errors are never encrypted; error codes must be readable by compliance middleware |

**Override `#publish`**: Same default-exchange override pattern as `Fleet::Response`.

**Override `#headers`**: Merges `error_headers` in addition to base LLM headers.

**Private methods:**

| Method | Return | Behavior |
|--------|--------|----------|
| `message_id_prefix` | `String` | `'err'` — produces `err_<uuid>` message IDs |
| `error_headers` | `Hash` | Reads `@options.dig(:error, :code)` and adds `'x-legion-fleet-error' => code.to_s` if present |

**Error code registry** (from wire protocol — include as a frozen constant `ERROR_CODES`):

| Code | Category | Retriable | Source |
|------|----------|-----------|--------|
| `model_not_loaded` | `worker` | `false` | Worker |
| `ollama_unavailable` | `worker` | `true` | Worker |
| `inference_failed` | `worker` | `true` | Worker |
| `inference_timeout` | `worker` | `true` | Worker |
| `invalid_token` | `auth` | `false` | Worker |
| `token_expired` | `auth` | `false` | Worker |
| `payload_too_large` | `validation` | `false` | Worker |
| `unsupported_type` | `validation` | `false` | Worker |
| `unsupported_streaming` | `validation` | `false` | Worker |
| `no_fleet_queue` | `dispatch` | `false` | Requester (basic.return) |
| `fleet_backpressure` | `dispatch` | `true` | Requester (basic.nack) |
| `fleet_timeout` | `dispatch` | `true` | Requester (timeout) |

**JSON body**: message_context (copied from request), error hash (`code`, `message`,
`retriable`, `retry_after`, `category`, `provider`), `worker_node`, timestamps.

---

### `Legion::LLM::Metering::Exchange`

**File**: `lib/legion/llm/metering/exchange.rb`

Declares the `llm.metering` topic exchange. Single source of truth for the exchange name.

```ruby
class Legion::LLM::Metering::Exchange < ::Legion::Transport::Exchange
  def exchange_name = 'llm.metering'
  def default_type  = 'topic'
end
```

Exchange is durable. Metering events survive broker restarts even if the consumer
(lex-llm-ledger) is temporarily down.

---

### `Legion::LLM::Metering::Event`

**File**: `lib/legion/llm/metering/event.rb`

Metering event message. Published after every inference call (local, fleet, or direct).

```ruby
class Legion::LLM::Metering::Event < Legion::LLM::Transport::Message
```

**AMQP property methods:**

| Method | Return | Value |
|--------|--------|-------|
| `type` | `String` | `'llm.metering.event'` |
| `exchange` | Class | `Legion::LLM::Metering::Exchange` |
| `routing_key` | `String` | `"metering.#{@options[:request_type]}"` — e.g., `metering.chat`, `metering.embed` |
| `priority` | `Integer` | `0` — best-effort |
| `encrypt?` | `Boolean` | `false` — metering contains no sensitive content |
| `expiration` | `nil` | Metering events must not expire (consumed by durable queue) |

**Override `#headers`**: Merges `tier_header` — adds `x-legion-llm-tier` if `@options[:tier]` is set.

**Private methods:**

| Method | Return | Behavior |
|--------|--------|----------|
| `message_id_prefix` | `String` | `'meter'` |
| `tier_header` | `Hash` | `{ 'x-legion-llm-tier' => @options[:tier].to_s }` if `:tier` is set |

**JSON body** (from wire protocol): message_context, node_id, worker_id, agent_id, task_id,
request_type, tier, provider, model_id, input_tokens, output_tokens, thinking_tokens,
total_tokens, latency_ms, wall_clock_ms, cost_usd, routing_reason, recorded_at, billing.

---

### `Legion::LLM::Metering`

**File**: `lib/legion/llm/metering.rb`

Public module API for emitting metering events. Replaces `Steps::Metering.publish_or_spool`
as the canonical interface. Steps::Metering is kept and updated to delegate here.

```ruby
module Legion::LLM::Metering
  module_function

  def emit(event)        # Hash → :published | :spooled | :dropped
  def flush_spool        # → Integer (count flushed)
end
```

**`emit(event)`**:
- Accepts a hash matching the `Metering::Event` body fields
- If transport is connected: instantiates `Metering::Event.new(**event)` and calls `.publish`; returns `:published`
- If transport is offline but `Legion::Data::Spool` is available: spools to disk; returns `:spooled`
- Otherwise: logs warn and returns `:dropped`
- Never raises — all errors are caught and logged

**`flush_spool`**:
- Returns `0` unless both spool and transport are available
- Calls `Legion::Data::Spool.for(Legion::LLM).flush(:metering) { |event| emit(event) }`
- Returns count of flushed events

**Transport availability check** (same pattern as existing `Steps::Metering`):
```ruby
def transport_connected?
  !!(defined?(Legion::Transport) &&
     Legion::Transport.respond_to?(:connected?) &&
     Legion::Transport.connected?)
end
```

---

### `Legion::LLM::Audit::Exchange`

**File**: `lib/legion/llm/audit/exchange.rb`

Declares the `llm.audit` topic exchange. Single source of truth. Both `PromptEvent` and
`ToolEvent` use this exchange (different routing keys, different queues).

Note: There is already a `Legion::LLM::Transport::Exchanges::Audit` class at
`lib/legion/llm/transport/exchanges/audit.rb` that defines `exchange_name 'llm.audit'`
without a type declaration. The new `Audit::Exchange` supersedes it and adds the `:topic`
type declaration. The existing `AuditEvent` message references the old class — it will
continue to work until `AuditPublisher` is updated. Do NOT delete the old class yet.

```ruby
class Legion::LLM::Audit::Exchange < ::Legion::Transport::Exchange
  def exchange_name = 'llm.audit'
  def default_type  = 'topic'
end
```

---

### `Legion::LLM::Audit::PromptEvent`

**File**: `lib/legion/llm/audit/prompt_event.rb`

Full prompt + response audit record. Always encrypted. Contains sensitive content
(user messages, system prompts, responses) — encrypted at rest and in transit.

```ruby
class Legion::LLM::Audit::PromptEvent < Legion::LLM::Transport::Message
```

**AMQP property methods:**

| Method | Return | Value |
|--------|--------|-------|
| `type` | `String` | `'llm.audit.prompt'` |
| `exchange` | Class | `Legion::LLM::Audit::Exchange` |
| `routing_key` | `String` | `"audit.prompt.#{@options[:request_type]}"` — e.g., `audit.prompt.chat` |
| `priority` | `Integer` | `0` — audit is best-effort |
| `encrypt?` | `Boolean` | `true` — always; sets `content_encoding: 'encrypted/cs'` |
| `expiration` | `nil` | Audit records must not expire |

**Override `#headers`**: Merges classification, caller, retention, and tier headers.

**Private methods:**

| Method | Return | Behavior |
|--------|--------|----------|
| `message_id_prefix` | `String` | `'audit_prompt'` |
| `classification_headers` | `Hash` | Reads `@options[:classification]`; sets `x-legion-classification`, `x-legion-contains-phi`, `x-legion-jurisdictions` (comma-joined array) |
| `caller_headers` | `Hash` | Reads `@options.dig(:caller, :requested_by)`; sets `x-legion-caller-identity`, `x-legion-caller-type` |
| `retention_headers` | `Hash` | Reads `@options.dig(:classification, :retention)`; sets `x-legion-retention` |
| `tier_header` | `Hash` | Reads `@options[:tier]`; sets `x-legion-llm-tier` |

**JSON body** (encrypted, see wire protocol): message_context, response_message_id,
request (system, messages, tools, generation, stream, context_strategy), response (message,
tools, stop), routing (provider, model, tier, strategy, escalated, latency_ms), tokens,
cost, caller, agent, classification, billing, timestamps, quality, audit, tracing.

---

### `Legion::LLM::Audit::ToolEvent`

**File**: `lib/legion/llm/audit/tool_event.rb`

Tool call audit record. Always encrypted. Contains tool arguments and results.

```ruby
class Legion::LLM::Audit::ToolEvent < Legion::LLM::Transport::Message
```

**AMQP property methods:**

| Method | Return | Value |
|--------|--------|-------|
| `type` | `String` | `'llm.audit.tool'` |
| `exchange` | Class | `Legion::LLM::Audit::Exchange` |
| `routing_key` | `String` | `"audit.tool.#{@options[:tool_name]}"` — e.g., `audit.tool.list_files` |
| `priority` | `Integer` | `0` |
| `encrypt?` | `Boolean` | `true` — always |
| `expiration` | `nil` | Audit records must not expire |

**Override `#headers`**: Merges `tool_headers` and `classification_headers`.

**Private methods:**

| Method | Return | Behavior |
|--------|--------|----------|
| `message_id_prefix` | `String` | `'audit_tool'` |
| `tool_headers` | `Hash` | Reads `@options[:tool_call]`; sets `x-legion-tool-name`, `x-legion-tool-source-type`, `x-legion-tool-source-server`, `x-legion-tool-status` |
| `classification_headers` | `Hash` | Sets `x-legion-classification`, `x-legion-contains-phi` |

**JSON body** (encrypted): message_context, tool_call (id, name, arguments, source, status,
duration_ms, result, error), caller, agent, timestamps.

---

### `Legion::LLM::Audit`

**File**: `lib/legion/llm/audit.rb`

Public module API for emitting audit events.

```ruby
module Legion::LLM::Audit
  module_function

  def emit_prompt(event)   # Hash → :published | :dropped
  def emit_tools(event)    # Hash → :published | :dropped
end
```

**`emit_prompt(event)`**:
- Accepts hash matching `Audit::PromptEvent` body fields
- If transport is connected: instantiates `Audit::PromptEvent.new(**event)` and calls `.publish`; returns `:published`
- If transport is offline: logs warn; returns `:dropped` (audit does NOT spool — prompt data is too sensitive to write unencrypted to disk; if the AMQP channel is unavailable, the record is lost)
- Never raises

**`emit_tools(event)`**:
- Same pattern as `emit_prompt`, using `Audit::ToolEvent`
- Returns `:published` or `:dropped`
- Never raises

**Note on spool vs. drop**: Metering spools because it contains no sensitive data. Audit
does NOT spool because the body is sensitive and the spool is plaintext on disk. If
legion-crypt's disk-encryption spool is available in the future, this can be revisited.

---

### Updated: `Legion::LLM::Fleet::Dispatcher`

**File**: `lib/legion/llm/fleet/dispatcher.rb`

The dispatcher is the most significant change. It must be rebuilt to use `Fleet::Request`
and the publisher confirms / mandatory / `on_return` feedback pattern.

**New constants:**

```ruby
TIMEOUTS = {
  embed:    10,
  chat:     30,
  generate: 30,
  default:  30
}.freeze
```

**New/changed module-function methods:**

| Method | Signature | Return | Behavior |
|--------|-----------|--------|----------|
| `dispatch` | `(request:, message_context:, routing_key:, reply_to: nil, **opts)` | `Hash` | Top-level dispatch: builds `Fleet::Request`, publishes with `mandatory: true`, waits for reply |
| `build_routing_key` | `(provider:, request_type:, model:)` | `String` | Builds `llm.request.<provider>.<type>.<sanitized_model>`; sanitizes model name (`:` → `.`) |
| `sanitize_model` | `(model)` | `String` | `model.to_s.gsub(':', '.')` |
| `fleet_available?` | `()` | `Boolean` | `transport_ready? && fleet_enabled?` (unchanged) |
| `transport_ready?` | `()` | `Boolean` | Checks `Legion::Transport.connected?` (unchanged) |
| `fleet_enabled?` | `()` | `Boolean` | Reads `Legion::Settings[:llm][:routing][:use_fleet]` (unchanged) |
| `resolve_timeout` | `(request_type:, override: nil)` | `Integer` | Reads `settings[:routing][:fleet][:timeouts][request_type.to_sym]` or `TIMEOUTS[request_type.to_sym]` or `TIMEOUTS[:default]` |
| `error_result` | `(reason, message_context: {})` | `Hash` | Returns `{ success: false, error: reason, message_context: }` |
| `timeout_result` | `(correlation_id, timeout, message_context: {})` | `Hash` | Returns `{ success: false, error: 'fleet_timeout', correlation_id:, timeout:, message_context: }` |

**Changed: `publish_request`**:
- Instantiates `Legion::LLM::Fleet::Request.new(**opts)` where opts include `routing_key:`, `reply_to:`, `fleet_correlation_id:`, `message_context:`, `provider:`, `model:`, `request_type:`, `priority:`, `ttl:`
- Uses the channel with `confirm_select` already called
- Sets `mandatory: true` on publish (passed as option to the message's `#publish` or directly to the exchange)
- Returns correlation_id for reply tracking

**Channel management**: The dispatcher needs a single long-lived channel with confirms.
The channel is lazily initialized and held as a module-level ivar:

```ruby
@channel = nil
@channel_mutex = Mutex.new

def channel
  @channel_mutex.synchronize do
    return @channel if @channel&.open?
    @channel = Legion::Transport.connection.create_channel
    @channel.confirm_select
    @channel.on_return do |return_info, properties, payload|
      cid = properties.correlation_id
      ReplyDispatcher.fulfill_return(cid)
    end
    @channel
  end
end
```

**`wait_for_response`** — updated signature:
```ruby
def wait_for_response(correlation_id, timeout:, request_type: :default, message_context: {})
  future = ReplyDispatcher.register(correlation_id)
  result = future.value!(timeout)
  result || timeout_result(correlation_id, timeout, message_context: message_context)
rescue Concurrent::CancelledOperationError
  timeout_result(correlation_id, timeout, message_context: message_context)
ensure
  ReplyDispatcher.deregister(correlation_id)
end
```

---

### Updated: `Legion::LLM::Fleet::ReplyDispatcher`

**File**: `lib/legion/llm/fleet/reply_dispatcher.rb`

Two key additions: `on_nack` handling and type-aware delivery dispatch.

**New/changed methods:**

| Method | Signature | Return | Behavior |
|--------|-----------|--------|----------|
| `fulfill_return` | `(correlation_id)` | `nil` | Called by Dispatcher's `on_return` block; finds pending future and fulfills with `{ success: false, error: 'no_fleet_queue' }` |
| `fulfill_nack` | `(correlation_id)` | `nil` | Called by channel's `on_nack` block; fulfills with `{ success: false, error: 'fleet_backpressure' }` |
| `handle_delivery` | `(raw_payload, properties)` | `nil` | Updated: checks `properties[:type]` — if `'llm.fleet.error'`, normalizes to `{ success: false, error: ..., message_context: ... }`; if `'llm.fleet.response'`, normalizes to `{ success: true, ... }`; then fulfills future as before |

**`ensure_consumer`** update: The reply queue subscription must propagate `properties.type`
to `handle_delivery`:

```ruby
@consumer = queue.subscribe(manual_ack: false) do |_delivery, properties, body|
  props = {
    correlation_id: properties.correlation_id,
    type:           properties.type
  }
  handle_delivery(body, props)
end
```

---

### Updated: `Pipeline::Steps::Metering`

**File**: `lib/legion/llm/pipeline/steps/metering.rb`

Change `publish_event` to delegate to `Legion::LLM::Metering.emit` instead of depending
on `Gateway::Transport::Messages::MeteringEvent`.

**Before:**
```ruby
def publish_event(event)
  return unless defined?(Legion::Extensions::LLM::Gateway::Transport::Messages::MeteringEvent)
  Legion::Extensions::LLM::Gateway::Transport::Messages::MeteringEvent.new(**event).publish
end
```

**After:**
```ruby
def publish_event(event)
  Legion::LLM::Metering.emit(event)
end
```

`publish_or_spool` can be simplified or removed — its logic is now inside `Metering.emit`.
Keep `publish_or_spool` as a thin wrapper that calls `Metering.emit` so callers do not break.

---

### Updated: `Pipeline::AuditPublisher`

**File**: `lib/legion/llm/pipeline/audit_publisher.rb`

Change `publish` to delegate to `Legion::LLM::Audit.emit_prompt`. Also update `build_event`
to include `message_context` derived from the response.

**`build_event`** additions:
- Include `message_context:` derived from response fields (`request_id`, `conversation_id`, etc.)
- Include `request_type:` for routing key generation in `PromptEvent`
- Include `tier:` for tier header

**`publish`** change:
```ruby
def publish(request:, response:)
  event = build_event(request: request, response: response)
  Legion::LLM::Audit.emit_prompt(event)
  event
rescue StandardError => e
  handle_exception(e, level: :warn)
  nil
end
```

Remove the `begin/rescue LoadError` guard and the raw `Legion::Transport` check — that logic
moves into `Audit.emit_prompt`.

---

### Updated: `lib/legion/llm/settings.rb`

**`routing_defaults`** changes:

```ruby
def self.routing_defaults
  {
    enabled:        false,
    tier_priority:  %w[local fleet direct],   # NEW: three-tier order
    default_intent: { privacy: 'normal', capability: 'moderate', cost: 'normal' },
    tiers: {
      local: { provider: 'ollama' },
      fleet: {
        queue:            'llm.request',       # updated exchange name
        timeout_seconds:  30,                  # kept for backwards compat
        timeouts: {                            # NEW: per-type timeouts
          embed:    10,
          chat:     30,
          generate: 30,
          default:  30
        }
      },
      cloud: { providers: %w[bedrock anthropic] }
    },
    ...
  }
end
```

---

### Updated: `lib/legion/llm/fleet.rb`

Add requires for new files:

```ruby
require_relative 'fleet/exchange'
require_relative 'fleet/request'
require_relative 'fleet/response'
require_relative 'fleet/error'
require_relative 'fleet/dispatcher'
require_relative 'fleet/handler'
require_relative 'fleet/reply_dispatcher'
```

---

### Updated: `lib/legion/llm.rb`

Add requires after the existing `fleet` require:

```ruby
require 'legion/llm/metering'
require 'legion/llm/audit'
```

---

## Configuration

### Settings Reference (Complete)

```yaml
legion:
  llm:
    routing:
      tier_priority: [local, fleet, direct]  # default order

      tiers:
        fleet:
          timeouts:
            embed: 10
            chat: 30
            generate: 30
            default: 30
```

### Per-Node Examples

```yaml
# H100 GPU server (highest priority fleet worker)
legion:
  ollama:
    host: "http://localhost:11434"
    fleet:
      consumer_priority: 10    # declared in lex-ollama, not legion-llm

# Developer laptop in India (fleet only)
legion:
  llm:
    routing:
      tier_priority: [fleet]

# Developer laptop in Minnesota (has GPU + API keys)
legion:
  llm:
    routing:
      tier_priority: [local, fleet, direct]
```

---

## Test Plan

### Transport Base: `spec/legion/llm/transport/message_spec.rb`

| Test | What to verify |
|------|----------------|
| `message_context` | Returns `{}` when not set; returns hash when set via `@options[:message_context]` |
| `message` strips LLM envelope keys | `:message_context`, `:fleet_correlation_id`, `:provider`, `:model`, `:priority`, `:ttl` are absent from `#message` output |
| `message` keeps body fields | `:system`, `:messages`, `:tools`, `:request_type` are present in `#message` output |
| `message_id` auto-generates | Returns `'msg_<uuid>'` when not set |
| `message_id` uses prefix | Subclass with `message_id_prefix = 'req'` produces `'req_<uuid>'` |
| `correlation_id` reads `:fleet_correlation_id` | When `fleet_correlation_id: 'req_abc'` is set, `#correlation_id` returns `'req_abc'` |
| `correlation_id` falls through to super | When `:fleet_correlation_id` is absent, behaves like base class |
| `app_id` defaults to `'legion-llm'` | Without explicit `app_id:`, returns `'legion-llm'` |
| `app_id` overridable | `app_id: 'lex-ollama'` is respected |
| `llm_headers` includes provider | When `provider: 'ollama'`, headers include `'x-legion-llm-provider' => 'ollama'` |
| `llm_headers` includes model | When `model: 'qwen3.5:27b'`, headers include `'x-legion-llm-model' => 'qwen3.5:27b'` |
| `llm_headers` always has schema version | `'x-legion-llm-schema-version' => '1.0.0'` always present |
| `context_headers` promotes conversation_id | When `message_context: { conversation_id: 'conv_abc' }`, headers include `'x-legion-llm-conversation-id' => 'conv_abc'` |
| `context_headers` skips nil fields | When `message_context: {}`, no context headers added |
| `tracing_headers` returns empty hash | `tracing_headers` returns `{}` (stub) |

### Exchange Tests

**`spec/legion/llm/fleet/exchange_spec.rb`**:
- `exchange_name` returns `'llm.request'`
- `exchange_type` returns `:topic`

**`spec/legion/llm/metering/exchange_spec.rb`**:
- `exchange_name` returns `'llm.metering'`
- `exchange_type` returns `:topic`

**`spec/legion/llm/audit/exchange_spec.rb`**:
- `exchange_name` returns `'llm.audit'`
- `exchange_type` returns `:topic`

### `spec/legion/llm/fleet/request_spec.rb`

| Test | What to verify |
|------|----------------|
| `type` returns `'llm.fleet.request'` | |
| `routing_key` reads from options | `routing_key: 'llm.request.ollama.chat.llama3.2'` propagates correctly |
| `reply_to` reads from options | |
| `priority` maps `:critical` → `9` | |
| `priority` maps `:high` → `7` | |
| `priority` maps `:normal` → `5` | |
| `priority` maps `:low` → `2` | |
| `priority` passes integer through | `priority: 3` returns `3` |
| `priority` defaults to `5` for unknown symbol | `priority: :unknown` returns `5` |
| `expiration` converts TTL seconds to ms string | `ttl: 30` returns `'30000'` |
| `expiration` returns nil when no TTL | No `ttl:` → `nil` |
| `message_id` prefix is `'req'` | message_id starts with `'req_'` |
| Body excludes envelope keys | `:fleet_correlation_id`, `:routing_key`, `:priority`, `:ttl` absent from body |
| Body includes `message_context` | message_context appears in body, NOT stripped |
| Body includes `:request_type` | request_type in body (metering needs it) |

### `spec/legion/llm/fleet/response_spec.rb`

| Test | What to verify |
|------|----------------|
| `type` returns `'llm.fleet.response'` | |
| `routing_key` reads `:reply_to` | |
| `priority` returns `0` | |
| `expiration` returns `nil` | |
| `message_id` prefix is `'resp'` | |
| `app_id` defaults to `'legion-llm'` | Workers must override |
| `app_id` overridable to `'lex-ollama'` | |
| `headers` includes LLM + context headers | via inherited base methods |

### `spec/legion/llm/fleet/error_spec.rb`

| Test | What to verify |
|------|----------------|
| `type` returns `'llm.fleet.error'` | |
| `routing_key` reads `:reply_to` | |
| `priority` returns `0` | |
| `encrypt?` returns `false` | |
| `message_id` prefix is `'err'` | |
| `error_headers` adds `x-legion-fleet-error` | When `error: { code: 'model_not_loaded' }`, header set |
| `error_headers` skips header when code nil | No header added when error hash has no code |
| `app_id` overridable | `app_id: 'lex-ollama'` for worker errors |

### `spec/legion/llm/metering/event_spec.rb`

| Test | What to verify |
|------|----------------|
| `type` returns `'llm.metering.event'` | |
| `routing_key` builds from `:request_type` | `request_type: 'chat'` → `'metering.chat'` |
| `routing_key` handles nil request_type | Returns `'metering.'` (graceful) |
| `priority` returns `0` | |
| `encrypt?` returns `false` | |
| `message_id` prefix is `'meter'` | |
| `tier_header` adds `x-legion-llm-tier` | When `tier: 'fleet'`, header set |
| Body includes `:request_type` | Not stripped — metering body uses it |

### `spec/legion/llm/metering_spec.rb`

| Test | What to verify |
|------|----------------|
| `emit` returns `:dropped` when transport not connected | |
| `emit` calls `Metering::Event.new(**event).publish` when connected | Stub transport; verify instantiation |
| `emit` returns `:spooled` when spool available and transport down | |
| `emit` never raises | Force `Metering::Event.new` to raise; verify rescue |
| `flush_spool` returns `0` when spool unavailable | |
| `flush_spool` calls spool.flush with metering key | |

### `spec/legion/llm/audit/prompt_event_spec.rb`

| Test | What to verify |
|------|----------------|
| `type` returns `'llm.audit.prompt'` | |
| `routing_key` builds from `:request_type` | `request_type: 'chat'` → `'audit.prompt.chat'` |
| `encrypt?` returns `true` | Always |
| `message_id` prefix is `'audit_prompt'` | |
| `classification_headers` sets phi header | When `classification: { contains_phi: true }`, header is `'true'` |
| `classification_headers` sets jurisdiction header | When `classification: { jurisdictions: ['us', 'eu'] }`, header is `'us,eu'` |
| `caller_headers` sets identity and type | `caller: { requested_by: { identity: 'user:matt', type: 'user' } }` |
| `retention_headers` sets retention | `classification: { retention: 'permanent' }` → header `'permanent'` |
| `tier_header` sets tier | |

### `spec/legion/llm/audit/tool_event_spec.rb`

| Test | What to verify |
|------|----------------|
| `type` returns `'llm.audit.tool'` | |
| `routing_key` builds from `:tool_name` | `tool_name: 'list_files'` → `'audit.tool.list_files'` |
| `encrypt?` returns `true` | Always |
| `message_id` prefix is `'audit_tool'` | |
| `tool_headers` sets tool name, source, status | Full tool_call hash |
| `tool_headers` handles missing source gracefully | `tool_call: { name: 'foo' }` — no source crash |

### `spec/legion/llm/audit_spec.rb`

| Test | What to verify |
|------|----------------|
| `emit_prompt` returns `:dropped` when transport not connected | |
| `emit_prompt` publishes `PromptEvent` when connected | |
| `emit_prompt` does NOT spool | No spool call even when spool available |
| `emit_prompt` never raises | |
| `emit_tools` same pattern | |

### Updated Dispatcher Tests: `spec/legion/llm/fleet/dispatcher_spec.rb`

Add to existing tests:

| Test | What to verify |
|------|----------------|
| `build_routing_key` | `ollama`, `chat`, `qwen3.5:27b` → `llm.request.ollama.chat.qwen3.5.27b` |
| `sanitize_model` | `:` replaced with `.`; other chars unchanged |
| `resolve_timeout` uses per-type | `request_type: 'embed'` returns `10`; `'chat'` returns `30` |
| `resolve_timeout` reads settings | Settings override of `fleet.timeouts.chat: 60` is respected |
| `dispatch` returns `:no_fleet_queue` on return | Stub `fulfill_return`; verify error result |
| `dispatch` passes `message_context` through | `message_context` in result hash |

---

## Migration Notes

### Breaking Changes

None — all changes are additive or replace internal implementation details.

### Behavioral Changes for Existing Callers

**`Pipeline::Steps::Metering`**: `publish_event` now calls `Legion::LLM::Metering.emit`
instead of `Legion::Extensions::LLM::Gateway::Transport::Messages::MeteringEvent`. The
published AMQP message type changes from the gateway's format to `'llm.metering.event'`.
Any consumer expecting the old gateway format must be updated (but lex-llm-gateway's
`MeteringWriter` actor will be replaced by lex-llm-ledger's `Ledger::Metering::MeteringWriter`).

**`Pipeline::AuditPublisher`**: Audit events now publish as `Audit::PromptEvent` with type
`'llm.audit.prompt'` on routing key `audit.prompt.<type>`. The old `AuditEvent` used
routing key `llm.audit.complete` on the same exchange. If any consumer is bound to
`llm.audit.complete`, it will stop receiving events. Update binding or add new binding.

**`Fleet::Dispatcher`**: The correlation_id format changes from `"fleet_#{SecureRandom.hex(12)}"` to
`"req_#{SecureRandom.uuid}"` (generated by `Fleet::Request#message_id`). Callers that
pattern-match on `"fleet_"` prefix must be updated. The `@pending` map in `ReplyDispatcher`
uses the correlation_id as a key — internal only, no external impact.

**`Fleet::Dispatcher#dispatch` signature**: The existing signature is
`dispatch(model:, messages:, **opts)`. The new design passes a `Pipeline::Request` object
plus `message_context:`. The old signature is deprecated but can be kept as a shim during
transition:

```ruby
# Backwards-compatible shim (keep until lex-llm-gateway is fully decomposed)
def dispatch(model: nil, messages: nil, request: nil, message_context: {}, **opts)
  if request.nil? && (model || messages)
    # old calling convention: build a minimal request
    request = build_minimal_request(model: model, messages: messages, **opts)
  end
  dispatch_request(request: request, message_context: message_context, **opts)
end
```

### lex-llm-gateway Coexistence

During the transition period, both lex-llm-gateway and the new fleet classes may be loaded.
They write to different exchanges (`llm.inference` vs `llm.request`) — they will not
interfere. The pipeline's `Steps::Metering` is updated to use `Metering.emit` — if
lex-llm-gateway is still loaded, its `MeteringEvent` class is ignored.

The `Fleet::Dispatcher.fleet_enabled?` check still reads `settings[:routing][:use_fleet]`
— no change needed there. If `tier_priority` is set to `[local, fleet, direct]`, the Router
calls the new dispatcher.

### lex-ollama Compatibility

lex-ollama's existing `Transport::Messages::LlmResponse` (pre-fleet work) publishes to the
default exchange and already carries `correlation_id`. When lex-ollama is updated to use
`Legion::LLM::Fleet::Response`, the `type` property changes to `'llm.fleet.response'`.

The updated `ReplyDispatcher#handle_delivery` must handle BOTH old (no `type`) and new
(`type: 'llm.fleet.response'`) delivery formats during the transition:

```ruby
def handle_delivery(raw_payload, properties = {})
  payload = parse_payload(raw_payload)
  cid = properties[:correlation_id] || payload[:correlation_id]
  return unless cid

  future = @pending.delete(cid)
  return unless future

  # type-aware dispatch (new protocol) with fallback to legacy (no type)
  case properties[:type]
  when 'llm.fleet.error'
    future.fulfill(normalize_error(payload))
  else
    # 'llm.fleet.response' or legacy (no type)
    future.fulfill(payload)
  end
rescue StandardError => e
  handle_exception(e, level: :warn)
end
```

### Version Bump

These changes are functional — bump patch version in `lib/legion/llm/version.rb`.
Current version: `0.6.18` → new version: `0.6.19`.

---

## Summary Checklist

Implementation order by step:

- [ ] Step 1: `lib/legion/llm/transport/message.rb` + spec
- [ ] Step 2a: `lib/legion/llm/fleet/exchange.rb` + spec
- [ ] Step 2b: `lib/legion/llm/metering/exchange.rb` + spec
- [ ] Step 2c: `lib/legion/llm/audit/exchange.rb` + spec
- [ ] Step 3a: `lib/legion/llm/fleet/request.rb` + spec
- [ ] Step 3b: `lib/legion/llm/fleet/response.rb` + spec
- [ ] Step 3c: `lib/legion/llm/fleet/error.rb` + spec
- [ ] Step 3d: `lib/legion/llm/metering/event.rb` + spec
- [ ] Step 3e: `lib/legion/llm/audit/prompt_event.rb` + spec
- [ ] Step 3f: `lib/legion/llm/audit/tool_event.rb` + spec
- [ ] Step 4a: `lib/legion/llm/metering.rb` + spec
- [ ] Step 4b: `lib/legion/llm/audit.rb` + spec
- [ ] Step 5: Update `lib/legion/llm/fleet.rb` requires
- [ ] Step 6: Update `lib/legion/llm/fleet/dispatcher.rb` + extend dispatcher spec
- [ ] Step 7: Update `lib/legion/llm/fleet/reply_dispatcher.rb` + spec
- [ ] Step 8: Update `lib/legion/llm/pipeline/steps/metering.rb`
- [ ] Step 9: Update `lib/legion/llm/pipeline/audit_publisher.rb`
- [ ] Step 10: Update `lib/legion/llm/settings.rb`
- [ ] Step 11: Update `lib/legion/llm.rb` requires + version bump
- [ ] Run full test suite: `bundle exec rspec`
- [ ] Run rubocop: `bundle exec rubocop -A`
- [ ] Update CHANGELOG.md

---

**Maintained By**: Matthew Iverson (@Esity)
**Last Updated**: 2026-04-08

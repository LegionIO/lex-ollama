# Implementation Plan: lex-llm-ledger

**Date**: 2026-04-08
**Author**: Matthew Iverson (@Esity)
**Status**: Draft
**Related**:
- [Fleet Wire Protocol](2026-04-08-fleet-wire-protocol.md)
- [Fleet LLM Architecture Design](2026-04-08-fleet-llm-architecture-design.md)

---

## Overview

`lex-llm-ledger` is a new Legion Extension that owns all LLM observability persistence.
It consumes three durable AMQP queues:

| Queue | Exchange | Binding | Message Type |
|---|---|---|---|
| `llm.metering.write` | `llm.metering` (topic) | `metering.#` | `llm.metering.event` |
| `llm.audit.prompts` | `llm.audit` (topic) | `audit.prompt.#` | `llm.audit.prompt` |
| `llm.audit.tools` | `llm.audit` (topic) | `audit.tool.#` | `llm.audit.tool` |

It writes records into three database tables owned by this extension, exposes usage-reporting
runners for querying those tables, and enforces retention policy (PHI TTL caps, session-only
cleanup). It never publishes to any exchange.

**Key design rules:**

- Only runs on nodes with database access (`legion-data` connected).
- Never runs on GPU fleet worker nodes — those nodes only need `lex-ollama`.
- Metering messages arrive in cleartext (`content_encoding: 'identity'`).
- Prompt and tool audit messages arrive encrypted (`content_encoding: 'encrypted/cs'`);
  `PromptWriter` and `ToolWriter` decrypt before writing.
- PHI-flagged records (`x-legion-contains-phi: true`) are capped at the configured PHI TTL
  regardless of requested retention.
- `SpoolFlush` drains the `legion-llm` on-disk spool when transport reconnects.

---

## Prerequisites

The following must exist in `legion-llm` before `lex-llm-ledger` can be implemented:

1. `Legion::LLM::Transport::Message` — LLM base message class
2. `Legion::LLM::Metering::Exchange` — declares `llm.metering` (topic, durable)
3. `Legion::LLM::Audit::Exchange` — declares `llm.audit` (topic, durable)
4. `Legion::LLM::Metering.flush_spool` — drains buffered metering events
5. `Legion::LLM::Metering::CostEstimator` — static pricing table (self-hosted = $0.00)

These are Day-0 deliverables for `legion-llm` per the architecture design doc. This plan
assumes they exist and focuses exclusively on `lex-llm-ledger`.

---

## File Inventory

```
lex-llm-ledger/
├── lex-llm-ledger.gemspec
├── Gemfile
├── Rakefile
├── CHANGELOG.md
├── README.md
├── lib/
│   ├── legion/
│   │   └── extensions/
│   │       └── llm/
│   │           └── ledger/
│   │               ├── version.rb
│   │               ├── actors/
│   │               │   ├── metering_writer.rb
│   │               │   ├── prompt_writer.rb
│   │               │   ├── tool_writer.rb
│   │               │   └── spool_flush.rb
│   │               ├── runners/
│   │               │   ├── metering.rb           # write_metering_record
│   │               │   ├── prompts.rb            # write_prompt_record
│   │               │   ├── tools.rb              # write_tool_record
│   │               │   ├── usage_reporter.rb     # summary, worker_usage, etc.
│   │               │   └── provider_stats.rb     # health_report, circuit_summary
│   │               ├── helpers/
│   │               │   ├── decryption.rb         # decrypt audit bodies
│   │               │   ├── retention.rb          # TTL policy resolution
│   │               │   └── queries.rb            # shared SQL helpers
│   │               ├── transport/
│   │               │   ├── exchanges/
│   │               │   │   ├── metering.rb       # reference llm.metering
│   │               │   │   └── audit.rb          # reference llm.audit
│   │               │   ├── queues/
│   │               │   │   ├── metering_write.rb
│   │               │   │   ├── audit_prompts.rb
│   │               │   │   └── audit_tools.rb
│   │               │   └── transport.rb
│   │               └── migrations/
│   │                   ├── 001_create_metering_records.rb
│   │                   ├── 002_create_prompt_records.rb
│   │                   └── 003_create_tool_records.rb
│   └── lex-llm-ledger.rb                         # top-level require entry point
└── spec/
    ├── spec_helper.rb
    ├── runners/
    │   ├── metering_spec.rb
    │   ├── prompts_spec.rb
    │   ├── tools_spec.rb
    │   ├── usage_reporter_spec.rb
    │   └── provider_stats_spec.rb
    ├── helpers/
    │   ├── decryption_spec.rb
    │   ├── retention_spec.rb
    │   └── queries_spec.rb
    └── actors/
        ├── metering_writer_spec.rb
        ├── prompt_writer_spec.rb
        ├── tool_writer_spec.rb
        └── spool_flush_spec.rb
```

---

## Gem Scaffold

### gemspec

```ruby
# frozen_string_literal: true

require_relative 'lib/legion/extensions/llm/ledger/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-llm-ledger'
  spec.version       = Legion::Extensions::LLM::Ledger::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'LEX LLM Ledger'
  spec.description   = 'LLM observability persistence for LegionIO — metering, audit, usage reporting'
  spec.homepage      = 'https://github.com/LegionIO/lex-llm-ledger'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri']        = spec.homepage
  spec.metadata['source_code_uri']     = spec.homepage
  spec.metadata['changelog_uri']       = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri']     = "#{spec.homepage}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'legion-data',      '>= 1.6'
  spec.add_dependency 'legion-crypt',     '>= 1.5'
  spec.add_dependency 'legion-transport', '>= 1.4'
end
```

### version.rb

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module LLM
      module Ledger
        VERSION = '0.1.0'
      end
    end
  end
end
```

### lib/lex-llm-ledger.rb (top-level require)

```ruby
# frozen_string_literal: true

require 'legion/extensions/llm/ledger/version'
require 'legion/extensions/llm/ledger/helpers/decryption'
require 'legion/extensions/llm/ledger/helpers/retention'
require 'legion/extensions/llm/ledger/helpers/queries'
require 'legion/extensions/llm/ledger/runners/metering'
require 'legion/extensions/llm/ledger/runners/prompts'
require 'legion/extensions/llm/ledger/runners/tools'
require 'legion/extensions/llm/ledger/runners/usage_reporter'
require 'legion/extensions/llm/ledger/runners/provider_stats'

if Legion::Extensions.const_defined?(:Core, false)
  require 'legion/extensions/llm/ledger/transport/exchanges/metering'
  require 'legion/extensions/llm/ledger/transport/exchanges/audit'
  require 'legion/extensions/llm/ledger/transport/queues/metering_write'
  require 'legion/extensions/llm/ledger/transport/queues/audit_prompts'
  require 'legion/extensions/llm/ledger/transport/queues/audit_tools'
  require 'legion/extensions/llm/ledger/transport/transport'
  require 'legion/extensions/llm/ledger/actors/metering_writer'
  require 'legion/extensions/llm/ledger/actors/prompt_writer'
  require 'legion/extensions/llm/ledger/actors/tool_writer'
  require 'legion/extensions/llm/ledger/actors/spool_flush'
end

module Legion
  module Extensions
    module LLM
      module Ledger
        extend Legion::Extensions::Core if Legion::Extensions.const_defined?(:Core, false)
      end
    end
  end
end
```

---

## Database Schema

### Table: `metering_records`

Stores one row per `llm.metering.event` message. Cleartext — no sensitive content.

```ruby
# migrations/001_create_metering_records.rb
Sequel.migration do
  change do
    create_table(:metering_records) do
      primary_key :id

      # message identity
      String   :message_id,       null: false, unique: true  # 'meter_<uuid>'
      String   :correlation_id,   null: false                # 'req_<uuid>' (fleet request)

      # message_context fields — all indexed for the query patterns in the wire protocol spec
      String   :conversation_id,  null: false
      String   :message_id_ctx,   null: false  # message_context.message_id (col alias avoids PK name clash)
      String   :parent_message_id
      Integer  :message_seq
      String   :request_id,       null: false
      String   :exchange_id

      # routing / provider
      String   :request_type,     null: false   # 'chat', 'embed', 'generate'
      String   :tier,             null: false   # 'local', 'fleet', 'direct'
      String   :provider,         null: false   # 'ollama', 'bedrock', etc.
      String   :model_id,         null: false

      # identity
      String   :node_id,          null: false
      String   :worker_id
      String   :agent_id
      String   :task_id

      # token counts
      Integer  :input_tokens,     null: false, default: 0
      Integer  :output_tokens,    null: false, default: 0
      Integer  :thinking_tokens,  null: false, default: 0
      Integer  :total_tokens,     null: false, default: 0

      # timing
      Integer  :latency_ms,       null: false, default: 0
      Integer  :wall_clock_ms,    null: false, default: 0

      # cost
      Float    :cost_usd,         null: false, default: 0.0

      # routing metadata
      String   :routing_reason

      # billing context (denormalized — no separate table needed)
      String   :cost_center
      String   :budget_id

      # bookkeeping
      String   :recorded_at,      null: false   # ISO 8601 from body
      DateTime :inserted_at,      null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_id]
      index [:message_id_ctx]
      index [:correlation_id]
      index [:provider, :model_id]
      index [:node_id]
      index [:worker_id]
      index [:recorded_at]
      index [:cost_center, :recorded_at]
    end
  end
end
```

**Column mapping from wire protocol metering body:**

| Body Field | Column | Notes |
|---|---|---|
| `message_context.conversation_id` | `conversation_id` | |
| `message_context.message_id` | `message_id_ctx` | Alias — `message_id` col is the AMQP message_id |
| `message_context.parent_message_id` | `parent_message_id` | |
| `message_context.message_seq` | `message_seq` | |
| `message_context.request_id` | `request_id` | |
| `message_context.exchange_id` | `exchange_id` | |
| `node_id` | `node_id` | |
| `worker_id` | `worker_id` | |
| `agent_id` | `agent_id` | |
| `task_id` | `task_id` | |
| `request_type` | `request_type` | |
| `tier` | `tier` | |
| `provider` | `provider` | |
| `model_id` | `model_id` | |
| `input_tokens` | `input_tokens` | |
| `output_tokens` | `output_tokens` | |
| `thinking_tokens` | `thinking_tokens` | |
| `total_tokens` | `total_tokens` | |
| `latency_ms` | `latency_ms` | |
| `wall_clock_ms` | `wall_clock_ms` | |
| `cost_usd` | `cost_usd` | |
| `routing_reason` | `routing_reason` | |
| `recorded_at` | `recorded_at` | |
| `billing.cost_center` | `cost_center` | Denormalized |
| `billing.budget_id` | `budget_id` | Denormalized |
| AMQP `message_id` property | `message_id` | `meter_<uuid>` |
| AMQP `correlation_id` property | `correlation_id` | `req_<uuid>` |

---

### Table: `prompt_records`

Stores one row per `llm.audit.prompt` message. Body is encrypted on the wire;
`PromptWriter` decrypts before writing. Content is stored cleartext in the DB
(the DB itself should be encrypted at rest at the infra layer — this is an application-level
record, not a secret). Retention TTL is enforced via `expires_at`.

```ruby
# migrations/002_create_prompt_records.rb
Sequel.migration do
  change do
    create_table(:prompt_records) do
      primary_key :id

      # message identity
      String   :message_id,         null: false, unique: true  # 'audit_prompt_<uuid>'
      String   :correlation_id,     null: false                # 'req_<uuid>'

      # message_context
      String   :conversation_id,    null: false
      String   :message_id_ctx,     null: false
      String   :parent_message_id
      Integer  :message_seq
      String   :request_id,         null: false
      String   :exchange_id
      String   :response_message_id                            # msg_006 (the assistant turn created)

      # routing
      String   :provider,           null: false
      String   :model_id,           null: false
      String   :tier
      String   :request_type

      # full content (from decrypted body — stored as JSON text)
      # Storing as serialized JSON avoids schema churn as request/response fields evolve.
      # Consumers query by message_context fields and load the blobs for inspection.
      Text     :request_json,        null: false   # body.request (system, messages, tools, generation)
      Text     :response_json,       null: false   # body.response (message, tools, stop)

      # token counts (duplicated from metering for join-free audit queries)
      Integer  :input_tokens,        default: 0
      Integer  :output_tokens,       default: 0
      Integer  :total_tokens,        default: 0

      # cost
      Float    :cost_usd,            default: 0.0

      # caller / agent
      String   :caller_identity                                # 'user:matt'
      String   :caller_type                                    # 'user', 'agent', 'service'
      String   :agent_id
      String   :task_id

      # classification (from cleartext headers — do not require decrypt to enforce)
      String   :classification_level                           # 'internal', 'restricted', etc.
      TrueClass :contains_phi,       null: false, default: false
      TrueClass :contains_pii,       null: false, default: false
      String   :jurisdictions                                  # comma-separated, e.g. 'us,eu'

      # quality
      Integer  :quality_score
      String   :quality_band

      # retention
      String   :retention_policy,   null: false, default: 'default'
      DateTime :expires_at                                     # nil = permanent; set by RetentionHelper

      # bookkeeping
      String   :recorded_at,        null: false               # ISO 8601 from response timestamps.returned
      DateTime :inserted_at,        null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_id]
      index [:message_id_ctx]
      index [:correlation_id]
      index [:response_message_id]
      index [:caller_identity]
      index [:provider, :model_id]
      index [:contains_phi]
      index [:expires_at]           # for retention cleanup job
      index [:inserted_at]
    end
  end
end
```

---

### Table: `tool_records`

Stores one row per tool call within an `llm.audit.tool` message. Body is encrypted;
`ToolWriter` decrypts before writing. Links back to `prompt_records` via `correlation_id`
(both share the same `req_<uuid>` as their AMQP `correlation_id` property).

```ruby
# migrations/003_create_tool_records.rb
Sequel.migration do
  change do
    create_table(:tool_records) do
      primary_key :id

      # message identity
      String   :message_id,          null: false, unique: true  # 'audit_tool_<uuid>'
      String   :correlation_id,      null: false                # 'req_<uuid>' — FK to prompt_records

      # message_context
      String   :conversation_id,     null: false
      String   :message_id_ctx,      null: false
      String   :parent_message_id
      Integer  :message_seq
      String   :request_id,          null: false
      String   :exchange_id                                      # exch_004 (the tool execution hop)

      # tool call fields (from tool_call block in decrypted body)
      String   :tool_call_id,        null: false                # tc_def456
      String   :tool_name,           null: false                # 'list_files'
      String   :tool_source_type                                # 'mcp', 'builtin', 'custom'
      String   :tool_source_server                              # 'filesystem'
      String   :tool_status,         null: false                # 'success', 'error'
      Integer  :tool_duration_ms,    default: 0

      # arguments and result stored as JSON text (schema varies per tool)
      Text     :arguments_json                                   # tool_call.arguments
      Text     :result_json                                      # tool_call.result (may be large)
      Text     :error_json                                       # tool_call.error (nil on success)

      # caller / agent (denormalized)
      String   :caller_identity
      String   :agent_id

      # classification (from cleartext headers)
      String   :classification_level
      TrueClass :contains_phi,       null: false, default: false

      # retention
      String   :retention_policy,    null: false, default: 'default'
      DateTime :expires_at

      # timing
      String   :tool_start_at                                    # ISO 8601
      String   :tool_end_at                                      # ISO 8601

      # bookkeeping
      DateTime :inserted_at,         null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_id]
      index [:message_id_ctx]
      index [:correlation_id]                                    # JOIN to prompt_records
      index [:tool_name]
      index [:tool_source_server, :tool_name]
      index [:tool_status]
      index [:contains_phi]
      index [:expires_at]
      index [:inserted_at]
    end
  end
end
```

---

## Transport Layer

### Exchanges (references — declare nothing, consume only)

`lex-llm-ledger` does not declare the `llm.metering` or `llm.audit` exchanges — those are
declared by `legion-llm` (the publisher). The exchange reference classes are passive wrappers
that resolve the exchange name for queue binding.

```ruby
# transport/exchanges/metering.rb
module Legion::Extensions::LLM::Ledger::Transport::Exchanges
  class Metering < Legion::Transport::Exchange
    def exchange_name = 'llm.metering'
    def default_type  = 'topic'
    def passive?      = true   # do not declare, only reference
  end
end

# transport/exchanges/audit.rb
module Legion::Extensions::LLM::Ledger::Transport::Exchanges
  class Audit < Legion::Transport::Exchange
    def exchange_name = 'llm.audit'
    def default_type  = 'topic'
    def passive?      = true
  end
end
```

### Queues

All three queues are **durable** (survive broker restart). Bindings use wildcard routing
keys so a single queue receives all subtypes.

```ruby
# transport/queues/metering_write.rb
# Exchange: llm.metering (topic)
# Binding:  metering.#   (catches metering.chat, metering.embed, metering.generate, etc.)
# Policy:   ledger-metering — max-length: 100000, overflow: drop-head
module Legion::Extensions::LLM::Ledger::Transport::Queues
  class MeteringWrite < Legion::Transport::Queue
    def queue_name    = 'llm.metering.write'
    def queue_options = { durable: true }
  end
end

# transport/queues/audit_prompts.rb
# Exchange: llm.audit (topic)
# Binding:  audit.prompt.#   (catches audit.prompt.chat, audit.prompt.embed, etc.)
# Policy:   ledger-audit — max-length: 50000, overflow: reject-publish
module Legion::Extensions::LLM::Ledger::Transport::Queues
  class AuditPrompts < Legion::Transport::Queue
    def queue_name    = 'llm.audit.prompts'
    def queue_options = { durable: true }
  end
end

# transport/queues/audit_tools.rb
# Exchange: llm.audit (topic)
# Binding:  audit.tool.#   (catches audit.tool.list_files, audit.tool.bash, etc.)
# Policy:   ledger-audit — max-length: 50000, overflow: reject-publish
module Legion::Extensions::LLM::Ledger::Transport::Queues
  class AuditTools < Legion::Transport::Queue
    def queue_name    = 'llm.audit.tools'
    def queue_options = { durable: true }
  end
end
```

### transport.rb

```ruby
# transport/transport.rb
begin
  require 'legion/extensions/transport'
rescue LoadError
  nil
end

module Legion::Extensions::LLM::Ledger::Transport
  extend Legion::Extensions::Transport if Legion::Extensions.const_defined?(:Transport, false)

  def self.additional_e_to_q
    [
      {
        exchange: Exchanges::Metering,
        queue:    Queues::MeteringWrite,
        binding:  'metering.#'
      },
      {
        exchange: Exchanges::Audit,
        queue:    Queues::AuditPrompts,
        binding:  'audit.prompt.#'
      },
      {
        exchange: Exchanges::Audit,
        queue:    Queues::AuditTools,
        binding:  'audit.tool.#'
      }
    ]
  end
end
```

---

## Actors

### MeteringWriter

Subscription actor consuming from `llm.metering.write`. Metering messages are cleartext
(`content_encoding: 'identity'`), priority 0 (best-effort). One worker thread is sufficient
for typical load; scale by deploying more ledger nodes (they all share the durable queue).

```ruby
# actors/metering_writer.rb
module Legion::Extensions::LLM::Ledger::Actor
  class MeteringWriter < Legion::Extensions::Actors::Subscription
    def runner_class    = Runners::Metering
    def runner_function = 'write_metering_record'
    def use_runner?     = false

    def queue
      @queue ||= begin
        q = Transport::Queues::MeteringWrite.new
        e = Transport::Exchanges::Metering.new
        q.bind(e, routing_key: 'metering.#')
        q
      end
    end
  end
end
```

### PromptWriter

Subscription actor consuming from `llm.audit.prompts`. Messages arrive with
`content_encoding: 'encrypted/cs'`. The actor passes the raw delivery to the runner;
decryption happens in `Helpers::Decryption` before the DB insert.

```ruby
# actors/prompt_writer.rb
module Legion::Extensions::LLM::Ledger::Actor
  class PromptWriter < Legion::Extensions::Actors::Subscription
    def runner_class    = Runners::Prompts
    def runner_function = 'write_prompt_record'
    def use_runner?     = false

    def queue
      @queue ||= begin
        q = Transport::Queues::AuditPrompts.new
        e = Transport::Exchanges::Audit.new
        q.bind(e, routing_key: 'audit.prompt.#')
        q
      end
    end
  end
end
```

### ToolWriter

Subscription actor consuming from `llm.audit.tools`. Same encryption contract as
`PromptWriter`.

```ruby
# actors/tool_writer.rb
module Legion::Extensions::LLM::Ledger::Actor
  class ToolWriter < Legion::Extensions::Actors::Subscription
    def runner_class    = Runners::Tools
    def runner_function = 'write_tool_record'
    def use_runner?     = false

    def queue
      @queue ||= begin
        q = Transport::Queues::AuditTools.new
        e = Transport::Exchanges::Audit.new
        q.bind(e, routing_key: 'audit.tool.#')
        q
      end
    end
  end
end
```

### SpoolFlush

Interval actor that runs every 60 seconds. Calls `Legion::LLM::Metering.flush_spool` to
drain events that were buffered to disk during transport outages. If the spool is empty or
`flush_spool` is not defined, it is a no-op.

```ruby
# actors/spool_flush.rb
module Legion::Extensions::LLM::Ledger::Actor
  class SpoolFlush < Legion::Extensions::Actors::Interval
    def interval = 60

    def run
      return unless defined?(Legion::LLM::Metering) &&
                    Legion::LLM::Metering.respond_to?(:flush_spool)

      Legion::LLM::Metering.flush_spool
    rescue StandardError => e
      Legion::Log.warn "[lex-llm-ledger] SpoolFlush error: #{e.message}"
    end
  end
end
```

---

## Runners

### Runners::Metering (`write_metering_record`)

Normalizes and inserts one row into `metering_records`. Called directly by `MeteringWriter`
(bypasses Legion::Runner).

```ruby
# runners/metering.rb
module Legion::Extensions::LLM::Ledger::Runners
  module Metering
    module_function

    # @param payload [Hash] decoded AMQP body from llm.metering.event
    # @param metadata [Hash] AMQP metadata (properties: message_id, correlation_id, timestamp)
    def write_metering_record(payload, metadata = {})
      ctx    = payload[:message_context] || {}
      props  = metadata[:properties] || {}
      record = build_metering_record(payload, ctx, props)

      ::Legion::Data::DB[:metering_records].insert(record)
      { result: :ok }
    rescue Sequel::UniqueConstraintViolation
      # Idempotent — redelivered messages with the same meter_ id are silently dropped.
      { result: :duplicate }
    rescue StandardError => e
      Legion::Log.error "[lex-llm-ledger] write_metering_record failed: #{e.message}"
      { result: :error, error: e.message }
    end

    private

    def build_metering_record(payload, ctx, props)
      billing = payload[:billing] || {}
      {
        message_id:       props[:message_id],
        correlation_id:   props[:correlation_id],
        conversation_id:  ctx[:conversation_id],
        message_id_ctx:   ctx[:message_id],
        parent_message_id: ctx[:parent_message_id],
        message_seq:      ctx[:message_seq],
        request_id:       ctx[:request_id],
        exchange_id:      ctx[:exchange_id],
        request_type:     payload[:request_type],
        tier:             payload[:tier],
        provider:         payload[:provider],
        model_id:         payload[:model_id],
        node_id:          payload[:node_id],
        worker_id:        payload[:worker_id],
        agent_id:         payload[:agent_id],
        task_id:          payload[:task_id],
        input_tokens:     payload[:input_tokens].to_i,
        output_tokens:    payload[:output_tokens].to_i,
        thinking_tokens:  payload[:thinking_tokens].to_i,
        total_tokens:     payload[:total_tokens].to_i,
        latency_ms:       payload[:latency_ms].to_i,
        wall_clock_ms:    payload[:wall_clock_ms].to_i,
        cost_usd:         payload[:cost_usd].to_f,
        routing_reason:   payload[:routing_reason],
        cost_center:      billing[:cost_center],
        budget_id:        billing[:budget_id],
        recorded_at:      payload[:recorded_at],
        inserted_at:      Time.now.utc
      }
    end
  end
end
```

### Runners::Prompts (`write_prompt_record`)

Decrypts the body, resolves retention TTL, and inserts into `prompt_records`. Classification
headers are read from cleartext AMQP headers — do not require decryption to enforce.

```ruby
# runners/prompts.rb
module Legion::Extensions::LLM::Ledger::Runners
  module Prompts
    module_function

    # @param payload [Hash]   raw (possibly still-encrypted) body
    # @param metadata [Hash]  AMQP delivery metadata (headers, properties)
    def write_prompt_record(payload, metadata = {})
      headers = metadata[:headers] || {}
      props   = metadata[:properties] || {}

      body = Helpers::Decryption.decrypt_if_needed(payload, metadata)
      ctx  = body[:message_context] || {}

      expires_at = Helpers::Retention.resolve(
        retention:    headers['x-legion-retention'],
        contains_phi: headers['x-legion-contains-phi'] == 'true'
      )

      routing   = body[:routing] || {}
      tokens    = body[:tokens]  || {}
      cost      = body[:cost]    || {}
      caller    = body.dig(:caller, :requested_by) || {}
      agent     = body[:agent]   || {}
      cls       = body[:classification] || {}
      quality   = body[:quality] || {}
      ts        = body[:timestamps] || {}

      record = {
        message_id:          props[:message_id],
        correlation_id:      props[:correlation_id],
        conversation_id:     ctx[:conversation_id],
        message_id_ctx:      ctx[:message_id],
        parent_message_id:   ctx[:parent_message_id],
        message_seq:         ctx[:message_seq],
        request_id:          ctx[:request_id],
        exchange_id:         ctx[:exchange_id],
        response_message_id: body[:response_message_id],
        provider:            routing[:provider],
        model_id:            routing[:model],
        tier:                routing[:tier],
        request_type:        headers['x-legion-llm-request-type'],
        request_json:        Legion::JSON.dump(body[:request]  || {}),
        response_json:       Legion::JSON.dump(body[:response] || {}),
        input_tokens:        tokens[:input].to_i,
        output_tokens:       tokens[:output].to_i,
        total_tokens:        tokens[:total].to_i,
        cost_usd:            cost[:estimated_usd].to_f,
        caller_identity:     caller[:identity],
        caller_type:         caller[:type],
        agent_id:            agent[:id],
        task_id:             agent[:task_id],
        classification_level: cls[:level] || headers['x-legion-classification'],
        contains_phi:        (cls[:contains_phi] || headers['x-legion-contains-phi'] == 'true') ? true : false,
        contains_pii:        cls[:contains_pii] ? true : false,
        jurisdictions:       Array(cls[:jurisdictions]).join(','),
        quality_score:       quality[:score],
        quality_band:        quality[:band],
        retention_policy:    headers['x-legion-retention'] || 'default',
        expires_at:          expires_at,
        recorded_at:         ts[:returned] || ts[:provider_end],
        inserted_at:         Time.now.utc
      }

      ::Legion::Data::DB[:prompt_records].insert(record)
      { result: :ok }
    rescue Sequel::UniqueConstraintViolation
      { result: :duplicate }
    rescue StandardError => e
      Legion::Log.error "[lex-llm-ledger] write_prompt_record failed: #{e.message}"
      { result: :error, error: e.message }
    end
  end
end
```

### Runners::Tools (`write_tool_record`)

Decrypts the body and inserts into `tool_records`. The `correlation_id` links the tool
record back to its parent prompt record (same `req_<uuid>` — both messages share the same
AMQP `correlation_id` property per the wire protocol spec).

```ruby
# runners/tools.rb
module Legion::Extensions::LLM::Ledger::Runners
  module Tools
    module_function

    def write_tool_record(payload, metadata = {})
      headers = metadata[:headers] || {}
      props   = metadata[:properties] || {}

      body = Helpers::Decryption.decrypt_if_needed(payload, metadata)
      ctx  = body[:message_context] || {}
      tc   = body[:tool_call]       || {}
      src  = tc[:source]            || {}
      cls  = body[:classification]  || {}
      ts   = body[:timestamps]      || {}
      caller = body.dig(:caller, :requested_by) || {}
      agent  = body[:agent] || {}

      expires_at = Helpers::Retention.resolve(
        retention:    headers['x-legion-retention'],
        contains_phi: headers['x-legion-contains-phi'] == 'true'
      )

      record = {
        message_id:           props[:message_id],
        correlation_id:       props[:correlation_id],
        conversation_id:      ctx[:conversation_id],
        message_id_ctx:       ctx[:message_id],
        parent_message_id:    ctx[:parent_message_id],
        message_seq:          ctx[:message_seq],
        request_id:           ctx[:request_id],
        exchange_id:          ctx[:exchange_id],
        tool_call_id:         tc[:id],
        tool_name:            tc[:name] || headers['x-legion-tool-name'],
        tool_source_type:     src[:type]   || headers['x-legion-tool-source-type'],
        tool_source_server:   src[:server] || headers['x-legion-tool-source-server'],
        tool_status:          tc[:status]  || headers['x-legion-tool-status'],
        tool_duration_ms:     tc[:duration_ms].to_i,
        arguments_json:       Legion::JSON.dump(tc[:arguments] || {}),
        result_json:          Legion::JSON.dump(tc[:result]),
        error_json:           Legion::JSON.dump(tc[:error]),
        caller_identity:      caller[:identity],
        agent_id:             agent[:id],
        classification_level: cls[:level] || headers['x-legion-classification'],
        contains_phi:         (cls[:contains_phi] || headers['x-legion-contains-phi'] == 'true') ? true : false,
        retention_policy:     headers['x-legion-retention'] || 'default',
        expires_at:           expires_at,
        tool_start_at:        ts[:tool_start],
        tool_end_at:          ts[:tool_end],
        inserted_at:          Time.now.utc
      }

      ::Legion::Data::DB[:tool_records].insert(record)
      { result: :ok }
    rescue Sequel::UniqueConstraintViolation
      { result: :duplicate }
    rescue StandardError => e
      Legion::Log.error "[lex-llm-ledger] write_tool_record failed: #{e.message}"
      { result: :error, error: e.message }
    end
  end
end
```

### Runners::UsageReporter

Query runners for usage summaries, worker breakdowns, and budget checks. These are called
via Legion task chains, not AMQP subscriptions — they are on-demand.

```ruby
# runners/usage_reporter.rb
module Legion::Extensions::LLM::Ledger::Runners
  module UsageReporter
    module_function

    # Aggregate token/cost summary for a time window.
    #
    # @param since  [Time, String] start of window (default: 24h ago)
    # @param until_ [Time, String] end of window (default: now)
    # @param period [String] 'hour', 'day', 'week', 'month' — auto-sets since/until_ if given
    # @param group_by [String, nil] 'provider', 'model_id', 'node_id', 'cost_center'
    def summary(since: nil, until_: nil, period: nil, group_by: nil)
      ds = ::Legion::Data::DB[:metering_records]
      ds = apply_time_window(ds, since, until_, period)
      ds = ds.group_and_count(group_by.to_sym) if group_by
      ds.select_append(
        Sequel.function(:SUM, :input_tokens).as(:total_input_tokens),
        Sequel.function(:SUM, :output_tokens).as(:total_output_tokens),
        Sequel.function(:SUM, :total_tokens).as(:grand_total_tokens),
        Sequel.function(:SUM, :cost_usd).as(:total_cost_usd),
        Sequel.function(:AVG, :latency_ms).as(:avg_latency_ms),
        Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count)
      ).all
    end

    # Per-worker breakdown.
    def worker_usage(worker_id:, since: nil, until_: nil, period: nil)
      ds = ::Legion::Data::DB[:metering_records].where(worker_id: worker_id)
      ds = apply_time_window(ds, since, until_, period)
      ds.select(
        :provider, :model_id, :request_type,
        Sequel.function(:SUM, :total_tokens).as(:total_tokens),
        Sequel.function(:SUM, :cost_usd).as(:cost_usd),
        Sequel.function(:COUNT, Sequel.lit('*')).as(:count)
      ).group(:provider, :model_id, :request_type).all
    end

    # Check whether a budget has been exceeded.
    # Returns { budget_usd:, spent_usd:, remaining_usd:, exceeded: bool, threshold_reached: bool }
    def budget_check(budget_id:, budget_usd:, threshold: 0.8, period: 'month')
      ds = ::Legion::Data::DB[:metering_records]
             .where(budget_id: budget_id)
      ds = apply_time_window(ds, nil, nil, period)
      spent = ds.sum(:cost_usd).to_f

      {
        budget_id:          budget_id,
        budget_usd:         budget_usd.to_f,
        spent_usd:          spent,
        remaining_usd:      [budget_usd.to_f - spent, 0.0].max,
        exceeded:           spent > budget_usd.to_f,
        threshold_reached:  spent >= budget_usd.to_f * threshold.to_f
      }
    end

    # Top N consumers (nodes, agents, or cost centers).
    def top_consumers(limit: 10, group_by: 'node_id', since: nil, until_: nil, period: 'day')
      col = group_by.to_sym
      ds  = ::Legion::Data::DB[:metering_records]
      ds  = apply_time_window(ds, since, until_, period)
      ds.select(
        col,
        Sequel.function(:SUM, :total_tokens).as(:total_tokens),
        Sequel.function(:SUM, :cost_usd).as(:cost_usd),
        Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count)
      ).group(col)
       .order(Sequel.desc(:cost_usd))
       .limit(limit)
       .all
    end

    private

    def apply_time_window(ds, since, until_, period)
      if period
        since  = period_start(period)
        until_ = Time.now.utc
      end
      ds = ds.where { inserted_at >= since  } if since
      ds = ds.where { inserted_at <= until_ } if until_
      ds
    end

    def period_start(period)
      now = Time.now.utc
      case period.to_s
      when 'hour'  then now - 3600
      when 'day'   then now - 86_400
      when 'week'  then now - 604_800
      when 'month' then now - 2_592_000
      else              now - 86_400
      end
    end
  end
end
```

### Runners::ProviderStats

Health and circuit-breaker summary based on metering records. Detects error rates from
missing records (no `total_tokens` data for a window) vs. provider-reported stop reasons
in prompt records.

```ruby
# runners/provider_stats.rb
module Legion::Extensions::LLM::Ledger::Runners
  module ProviderStats
    module_function

    # High-level health report across all providers seen in the last 24 hours.
    def health_report
      ds = ::Legion::Data::DB[:metering_records]
             .where { inserted_at >= Time.now.utc - 86_400 }
             .select(
               :provider,
               Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count),
               Sequel.function(:SUM, :total_tokens).as(:total_tokens),
               Sequel.function(:AVG, :latency_ms).as(:avg_latency_ms),
               Sequel.function(:MAX, :latency_ms).as(:max_latency_ms)
             )
             .group(:provider)
             .all

      ds.map do |row|
        row.merge(status: latency_status(row[:avg_latency_ms]))
      end
    end

    # Summary of providers by request_count and error indicators over a window.
    def circuit_summary(period: 'hour')
      since = Helpers::Queries.period_start(period)
      ::Legion::Data::DB[:metering_records]
        .where { inserted_at >= since }
        .select(
          :provider, :tier,
          Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count),
          Sequel.function(:AVG,   :latency_ms).as(:avg_latency_ms),
          Sequel.function(:SUM,   :cost_usd).as(:cost_usd)
        )
        .group(:provider, :tier)
        .order(Sequel.desc(:request_count))
        .all
    end

    # Detailed stats for a single provider.
    def provider_detail(provider:, period: 'day')
      since = Helpers::Queries.period_start(period)
      ::Legion::Data::DB[:metering_records]
        .where(provider: provider)
        .where { inserted_at >= since }
        .select(
          :model_id, :request_type,
          Sequel.function(:COUNT, Sequel.lit('*')).as(:count),
          Sequel.function(:SUM,   :total_tokens).as(:total_tokens),
          Sequel.function(:AVG,   :latency_ms).as(:avg_latency_ms),
          Sequel.function(:SUM,   :cost_usd).as(:cost_usd)
        )
        .group(:model_id, :request_type)
        .order(Sequel.desc(:count))
        .all
    end

    private

    def latency_status(avg_ms)
      return :unknown if avg_ms.nil?
      return :healthy  if avg_ms < 2_000
      return :degraded if avg_ms < 8_000

      :critical
    end
  end
end
```

---

## Helpers

### Helpers::Decryption

Handles the `content_encoding: 'encrypted/cs'` contract. The `encrypted/cs` scheme is
implemented by `Legion::Crypt`. If the message is not encrypted (`content_encoding:
'identity'` or absent), the payload is returned as-is.

```ruby
# helpers/decryption.rb
module Legion::Extensions::LLM::Ledger::Helpers
  module Decryption
    module_function

    # Decrypt the message body if content_encoding indicates encryption.
    # Audit messages use 'encrypted/cs' (Legion::Crypt symmetric encryption).
    #
    # @param payload  [Hash, String] decoded or raw AMQP body
    # @param metadata [Hash]         AMQP delivery metadata
    # @return [Hash] decrypted and JSON-parsed body
    def decrypt_if_needed(payload, metadata = {})
      encoding = metadata.dig(:properties, :content_encoding).to_s

      return symbolize(payload) unless encoding == 'encrypted/cs'

      ensure_crypt_available!

      raw       = payload.is_a?(String) ? payload : Legion::JSON.dump(payload)
      decrypted = Legion::Crypt.decrypt(raw)
      Legion::JSON.load(decrypted, symbolize_names: true)
    rescue Legion::Crypt::DecryptionError => e
      raise DecryptionFailed, "Failed to decrypt audit record: #{e.message}"
    end

    private

    def ensure_crypt_available!
      return if defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:decrypt)

      raise DecryptionUnavailable, 'Legion::Crypt is required to read encrypted audit records'
    end

    def symbolize(hash)
      return hash if hash.is_a?(Hash) && hash.keys.first.is_a?(Symbol)

      Legion::JSON.load(Legion::JSON.dump(hash), symbolize_names: true)
    end
  end

  class DecryptionFailed    < StandardError; end
  class DecryptionUnavailable < StandardError; end
end
```

**Encryption contract details:**

- `content_encoding: 'encrypted/cs'` means the full JSON body was encrypted via
  `Legion::Crypt` before publishing.
- `Legion::Crypt` uses Vault transit (or a local key fallback) for symmetric encryption.
- The plaintext body after decryption is the full JSON documented in the wire protocol spec
  (Message 5 and Message 6).
- `lex-llm-ledger` never has access to raw PII/PHI during transit — it only decrypts at
  write time, and only nodes with `legion-crypt` configured and Vault access can do so.
- If `Legion::Crypt` is unavailable (no Vault, no keys), `DecryptionUnavailable` is raised
  and the actor should NACK the message for requeue. The message stays in the durable queue
  until the node gets credentials.

---

### Helpers::Retention

Resolves the effective `expires_at` timestamp from the `x-legion-retention` header,
the configured PHI TTL cap, and extension settings.

```ruby
# helpers/retention.rb
module Legion::Extensions::LLM::Ledger::Helpers
  module Retention
    # PHI TTL cap: records flagged contains_phi MUST NOT be retained longer than this.
    # Configurable via legion.llm_ledger.retention.phi_ttl_days (default: 30).
    # HIPAA Safe Harbor allows PHI retention up to 6 years, but operational default is 30 days.
    PHI_TTL_DEFAULT_DAYS = 30

    # Retention label → days (nil = permanent)
    RETENTION_MAP = {
      'default'    => nil,   # resolved from setting legion.llm_ledger.retention.default_days (90)
      'session_only' => nil, # cleaned up by session close event, not TTL (expires_at stays nil)
      'days_30'    => 30,
      'days_90'    => 90,
      'permanent'  => nil    # never auto-delete
    }.freeze

    module_function

    # Resolve the expires_at timestamp for a record.
    #
    # @param retention    [String, nil] value of x-legion-retention header
    # @param contains_phi [Boolean]     whether the record is PHI-flagged
    # @return [Time, nil] nil means never expire; Time means delete after this point
    def resolve(retention:, contains_phi: false)
      label = retention.to_s.empty? ? 'default' : retention.to_s
      days  = days_for_label(label)
      days  = apply_phi_cap(days, contains_phi)
      days ? Time.now.utc + (days * 86_400) : nil
    end

    # Cleanup hook: delete all records where expires_at has passed.
    # Called by a future RetentionSweeper actor (not in v1 scope, but schema supports it).
    def expired_ids(table)
      ::Legion::Data::DB[table]
        .where { expires_at <= Time.now.utc }
        .select_map(:id)
    end

    private

    def days_for_label(label)
      return RETENTION_MAP[label] if RETENTION_MAP.key?(label)

      default_days
    end

    def apply_phi_cap(days, contains_phi)
      return days unless contains_phi

      phi_cap = phi_ttl_days
      return phi_cap if days.nil?

      [days, phi_cap].min
    end

    def default_days
      # Read from settings if available; fall back to 90 days.
      if defined?(Legion::Settings) &&
         Legion::Settings.respond_to?(:dig) &&
         Legion::Settings.dig(:legion, :llm_ledger, :retention, :default_days)
        Legion::Settings.dig(:legion, :llm_ledger, :retention, :default_days).to_i
      else
        90
      end
    end

    def phi_ttl_days
      if defined?(Legion::Settings) &&
         Legion::Settings.respond_to?(:dig) &&
         Legion::Settings.dig(:legion, :llm_ledger, :retention, :phi_ttl_days)
        Legion::Settings.dig(:legion, :llm_ledger, :retention, :phi_ttl_days).to_i
      else
        PHI_TTL_DEFAULT_DAYS
      end
    end
  end
end
```

**Retention rules enforced:**

| `x-legion-retention` header | Default `expires_at` behavior |
|---|---|
| `default` or absent | `Time.now + 90.days` (configurable via settings) |
| `session_only` | `nil` (no TTL — cleaned up by session-close event, not this actor) |
| `days_30` | `Time.now + 30.days` |
| `days_90` | `Time.now + 90.days` |
| `permanent` | `nil` (never expires) |

**PHI cap override:** If `x-legion-contains-phi: true` header is present, the computed
`expires_at` is capped at `phi_ttl_days` (default 30), regardless of the requested
retention label. `permanent` PHI records are therefore capped at 30 days. This enforces
HIPAA minimum necessary / data minimization.

**Session-only cleanup:** `session_only` records have `expires_at: nil` because their
lifecycle is driven by a conversation-end event, not a TTL. A future `RetentionSweeper`
actor will handle this by subscribing to a `conversation.closed` event and deleting
prompt/tool records matching `conversation_id` where `retention_policy = 'session_only'`.
This is deferred from v1 (Open Question #10 in architecture doc).

---

### Helpers::Queries

Shared query utilities used by `UsageReporter` and `ProviderStats`.

```ruby
# helpers/queries.rb
module Legion::Extensions::LLM::Ledger::Helpers
  module Queries
    module_function

    def period_start(period)
      now = Time.now.utc
      case period.to_s
      when 'hour'  then now - 3600
      when 'day'   then now - 86_400
      when 'week'  then now - 604_800
      when 'month' then now - 2_592_000
      else              now - 86_400
      end
    end
  end
end
```

---

## Configuration Schema

Settings are read via `Legion::Settings`. All keys are optional with defaults.

```yaml
legion:
  llm_ledger:
    # Retention policy
    retention:
      default_days: 90          # default retention for non-PHI, non-labeled records
      phi_ttl_days: 30          # hard cap for any PHI-flagged record (HIPAA default)

    # Database (uses legion-data connection by default — no separate config needed)
    # If a dedicated ledger DB is required, override here:
    # database:
    #   connection: postgresql://ledger-user:pass@db-host/ledger_db

    # Audit decryption
    # decryption is handled by legion-crypt using Vault transit.
    # No extra config needed if Vault is already configured in legion-crypt settings.
    # If decryption is disabled (no Vault), prompt and tool records cannot be written.
    decryption:
      enabled: true             # set false to skip audit queues without raising errors

    # Actor concurrency (number of subscription threads per actor)
    concurrency:
      metering_writer: 2        # 2 threads for metering — high volume, fast inserts
      prompt_writer:   1        # 1 thread for prompts — decrypt is serialized
      tool_writer:     1        # 1 thread for tools

    # SpoolFlush interval (seconds)
    spool_flush_interval: 60
```

---

## Implementation Order

Phase 1: Scaffold and schema (no AMQP, no decrypt — testable in isolation)

1. Create gem scaffold: gemspec, Gemfile, Rakefile, version.rb, module skeleton
2. Write Sequel migrations (001, 002, 003)
3. Write `Helpers::Retention` with full spec coverage (pure Ruby, no DB dep)
4. Write `Helpers::Queries` (pure Ruby)
5. Write `Runners::Metering#write_metering_record` + specs (mocked DB)
6. Write `Runners::UsageReporter` + specs (mocked DB)
7. Write `Runners::ProviderStats` + specs (mocked DB)

Phase 2: Decryption and audit runners

8. Write `Helpers::Decryption` + specs (mock `Legion::Crypt`)
9. Write `Runners::Prompts#write_prompt_record` + specs
10. Write `Runners::Tools#write_tool_record` + specs

Phase 3: Transport and actors

11. Write transport exchanges (passive references)
12. Write transport queues (durable declarations)
13. Write `Actor::MeteringWriter` + spec
14. Write `Actor::PromptWriter` + spec
15. Write `Actor::ToolWriter` + spec
16. Write `Actor::SpoolFlush` + spec
17. Write `transport.rb` with `additional_e_to_q`

Phase 4: Top-level wiring and integration

18. Write `lib/lex-llm-ledger.rb` entry point
19. Write `Helpers::Client` (not applicable — no HTTP client in this extension)
20. Integration spec: end-to-end metering insert with real SQLite in-memory DB
21. rubocop pass, version bump to 0.1.0

---

## Class Specifications

### Module Namespace

```ruby
Legion::Extensions::LLM::Ledger            # extension root
Legion::Extensions::LLM::Ledger::Actor     # actors (subscription + interval)
Legion::Extensions::LLM::Ledger::Runners   # write + query runners
Legion::Extensions::LLM::Ledger::Helpers   # decryption, retention, queries
Legion::Extensions::LLM::Ledger::Transport # exchange + queue declarations
```

Note: the gem name is `lex-llm-ledger` and the module path is
`Legion::Extensions::LLM::Ledger` (not `Legion::Extensions::LlmLedger`). This follows the
`lex-azure-ai` → `Legion::Extensions::AzureAI` pattern of keeping the domain hierarchy
explicit in the module namespace.

### Actor Method Contracts

All subscription actors:
- `runner_class` — returns the runner module constant
- `runner_function` — returns the runner method name as a string
- `use_runner?` — returns `false` (bypass `Legion::Runner`, call module directly)
- `queue` — memoizes and returns the bound `Legion::Transport::Queue` instance

`SpoolFlush`:
- `interval` — returns 60 (seconds)
- `run` — calls `Legion::LLM::Metering.flush_spool` with error swallowing

### Runner Method Contracts

All write runners:
- Accept `(payload, metadata = {})` where `payload` is the decoded body hash
  and `metadata` contains `:properties` (AMQP BasicProperties) and `:headers`
- Return `{ result: :ok }` on success
- Return `{ result: :duplicate }` on `UniqueConstraintViolation` (idempotent)
- Return `{ result: :error, error: String }` on other failures
- Never raise — swallow and log all errors to avoid blocking the AMQP ack path

All query runners:
- Accept keyword arguments per method signature
- Return Array of Sequel result Hashes or a single Hash for scalar results
- Never mutate the database

---

## Dependencies

| Gem | Required | Purpose |
|---|---|---|
| `legion-data` >= 1.6 | Hard (gemspec) | Sequel DB connection, migration DSL |
| `legion-crypt` >= 1.5 | Hard (gemspec) | Decrypt `encrypted/cs` audit bodies |
| `legion-transport` >= 1.4 | Hard (gemspec) | Queue/Exchange base classes, actor base |
| `legion-json` | Soft (runtime) | JSON serialization — expected in Legion env |
| `legion-settings` | Soft (runtime) | Read retention config — graceful fallback if absent |
| `legion-logging` | Soft (runtime) | `Legion::Log.error/warn` — graceful fallback if absent |

`legion-data`, `legion-crypt`, and `legion-transport` are hard dependencies declared in
the gemspec because `lex-llm-ledger` cannot function without any of them. The three soft
dependencies (`legion-json`, `legion-settings`, `legion-logging`) are expected to be present
in any standard Legion runtime environment and are not declared in the gemspec.

---

## Test Plan

### Unit specs (no AMQP, no DB)

**`spec/helpers/retention_spec.rb`**
- `resolve(retention: 'default', contains_phi: false)` → `Time.now + 90.days` (within 1s)
- `resolve(retention: 'permanent', contains_phi: false)` → `nil`
- `resolve(retention: 'permanent', contains_phi: true)` → `Time.now + 30.days` (PHI cap wins)
- `resolve(retention: 'days_30', contains_phi: true)` → cap at `min(30, phi_cap)` = 30.days
- `resolve(retention: 'days_90', contains_phi: true)` → capped to `phi_ttl_days` (30 by default)
- `resolve(retention: 'session_only', contains_phi: false)` → `nil`
- Respects `legion.llm_ledger.retention.default_days` setting override
- Respects `legion.llm_ledger.retention.phi_ttl_days` setting override

**`spec/helpers/decryption_spec.rb`**
- With `content_encoding: 'identity'` → returns symbolized hash unchanged
- With `content_encoding: 'encrypted/cs'` and `Legion::Crypt` available → decrypts correctly
- With `content_encoding: 'encrypted/cs'` and `Legion::Crypt` unavailable → raises `DecryptionUnavailable`
- With bad ciphertext → raises `DecryptionFailed`
- Tolerates nil `content_encoding`

**`spec/helpers/queries_spec.rb`**
- `period_start('hour')` returns approx `Time.now - 3600`
- `period_start('month')` returns approx `Time.now - 2592000`
- Unknown period falls back to day

### Runner specs (SQLite in-memory)

**`spec/runners/metering_spec.rb`**
- Happy path: valid metering payload → row inserted with all columns mapped correctly
- `message_id` uniqueness: second insert of same `meter_uuid` → `{ result: :duplicate }`, no raise
- Nil `billing` block → `cost_center` and `budget_id` are nil in DB
- Zero `thinking_tokens` in payload → `0` in DB (not null)
- Returns `{ result: :ok }` on success
- DB error (non-unique) → returns `{ result: :error, error: ... }` and logs

**`spec/runners/prompts_spec.rb`**
- Cleartext payload (content_encoding absent) + valid body → row inserted
- Encrypted payload (content_encoding `encrypted/cs`) → `Decryption.decrypt_if_needed` called
- PHI header `x-legion-contains-phi: true` → `contains_phi: true` in DB, `expires_at` = PHI cap
- Non-PHI with `x-legion-retention: permanent` → `expires_at: nil`
- `response_message_id` from body mapped to column
- `request_json` and `response_json` are valid JSON strings
- Duplicate `audit_prompt_uuid` → `{ result: :duplicate }`

**`spec/runners/tools_spec.rb`**
- Happy path: decrypted tool payload → row inserted with `tool_name`, `tool_status`, `tool_duration_ms`
- `arguments_json` and `result_json` serialized as JSON strings
- `error_json` is `"null"` when `tool_call.error` is nil
- `correlation_id` matches the request's `req_uuid` (links to prompt_records)
- `x-legion-tool-name` header used as fallback when `tool_call.name` absent
- PHI cap applied when `x-legion-contains-phi: true`

**`spec/runners/usage_reporter_spec.rb`**
- `summary` with no arguments returns all records from last 24h
- `summary(period: 'hour')` only returns records within last hour
- `summary(group_by: 'provider')` groups by provider column
- `budget_check(budget_id: ..., budget_usd: 10.0)` returns correct `spent_usd`, `exceeded`, `threshold_reached`
- `top_consumers(limit: 3, group_by: 'node_id')` returns at most 3 rows ordered by cost_usd desc
- `worker_usage(worker_id: 'gpu-h100-01')` returns only records for that worker

**`spec/runners/provider_stats_spec.rb`**
- `health_report` returns all providers seen in last 24h with `status` key
- Latency < 2000ms → `status: :healthy`
- Latency 2000–8000ms → `status: :degraded`
- Latency > 8000ms → `status: :critical`
- `circuit_summary(period: 'hour')` returns grouped by provider + tier
- `provider_detail(provider: 'ollama', period: 'day')` returns only ollama rows

### Actor specs (stubbed queues)

**`spec/actors/metering_writer_spec.rb`**
- `runner_class` returns `Runners::Metering`
- `runner_function` returns `'write_metering_record'`
- `use_runner?` returns `false`
- `queue` binds `MeteringWrite` queue to `Metering` exchange with routing_key `metering.#`

**`spec/actors/prompt_writer_spec.rb`**
- Binds `AuditPrompts` queue to `Audit` exchange with routing_key `audit.prompt.#`

**`spec/actors/tool_writer_spec.rb`**
- Binds `AuditTools` queue to `Audit` exchange with routing_key `audit.tool.#`

**`spec/actors/spool_flush_spec.rb`**
- `interval` returns 60
- Calls `Legion::LLM::Metering.flush_spool` when it exists
- Does not raise when `Legion::LLM::Metering` is not defined
- Does not raise when `flush_spool` raises (swallows + logs)

---

## Open Items (Deferred from v1)

1. **RetentionSweeper actor** — interval actor that deletes rows where `expires_at <= now`.
   Schema supports it (indexed `expires_at` on all three tables), but the actor is not in v1.

2. **Session-only cleanup** — `retention_policy: 'session_only'` records have `expires_at: nil`.
   A `RetentionSweeper` subscribed to `conversation.closed` events will clean these up.
   Blocked by Open Question #10 (conversation lifecycle) in the architecture doc.

3. **Prompt record full-text search** — SQLite FTS5 index on `request_json` and `response_json`
   for semantic audit search. Useful but not required for v1.

4. **Worker-side metering duplication** — If fleet workers emit their own metering events
   (architecture Open Question #4), `metering_records` will receive two rows per inference
   (one from requester, one from worker). The `correlation_id` + `node_id` combination
   distinguishes them. No schema change needed, but `UsageReporter` queries must filter
   by `tier` or `node_id` to avoid double-counting.

5. **Budget alerts** — `budget_check` returns a hash but does not emit alerts. A future
   `BudgetWatcher` interval actor could call `budget_check` and publish a `llm.budget.alert`
   event when `threshold_reached` or `exceeded`.

6. **Prompt record size limits** — `request_json` and `response_json` can be very large
   (long context windows, tool results). Consider a `max_content_bytes` setting that
   truncates before insert with a `truncated: true` flag column.

# frozen_string_literal: true

require 'bundler/setup'
require 'securerandom'
begin
  require 'legion/transport'
rescue LoadError
  module Legion
    module Transport
      ENVELOPE_KEYS = %i[routing_key reply_to exchange].freeze unless const_defined?(:ENVELOPE_KEYS, false)

      def self.const_missing(name)
        const_set(name, Class.new)
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Stub Legion constants not present without a full Legion runtime.
# Defined BEFORE loading lex-ollama so the conditional transport/actor requires
# fire and the fleet classes are fully defined during the test suite.
#
# Legion::Extensions stubs (Core, Actors::Subscription) and
# Legion::LLM stubs (Transport::Message, Fleet::Exchange/Response/Error)
# are all defined in a single module reopening to satisfy Style/OneClassPerFile.
# ---------------------------------------------------------------------------
module Legion
  module Extensions
    module Core; end unless const_defined?(:Core, false)

    unless const_defined?(:Actors, false)
      module Actors
        class Subscription
          def initialize(**); end
          def runner_class    = raise(NotImplementedError)
          def runner_function = raise(NotImplementedError)
          def use_runner?     = true

          def process_message(payload, _metadata, _delivery_info)
            payload
          end
        end

        class Once
          def use_runner? = false
          def enabled?    = true
          def delay       = 1.0
        end

        class Every
          def use_runner? = false
          def enabled?    = true
          def time        = 1.0

          def handle_exception(error, **)
            raise error
          end

          def lex_name = :ollama
        end
      end
    end
  end

  module LLM
    module Transport
      class Message < ::Legion::Transport::Message
        LLM_ENVELOPE_KEYS = %i[fleet_correlation_id provider model ttl].freeze

        def message_context
          @options[:message_context] || {}
        end

        def message
          envelope = defined?(::Legion::Transport::ENVELOPE_KEYS) ? ::Legion::Transport::ENVELOPE_KEYS : []
          (@options || {}).except(*envelope, *LLM_ENVELOPE_KEYS)
        end

        def message_id
          @options[:message_id] || "#{message_id_prefix}_#{SecureRandom.uuid}"
        end

        def correlation_id
          @options[:fleet_correlation_id]
        end

        def app_id
          @options[:app_id] || 'legion-llm'
        end

        def type
          'llm.message'
        end

        private

        def message_id_prefix = 'msg'
      end
    end

    module Fleet
      class Exchange < ::Legion::Transport::Exchange
        def exchange_name = 'llm.fleet'
        def default_type  = 'topic'
      end

      class Response < Legion::LLM::Transport::Message
        def type        = 'llm.fleet.response'
        def routing_key = @options[:reply_to]
        def priority    = 0

        def publish(_options = @options); end

        private

        def message_id_prefix = 'resp'
      end

      class Error < Legion::LLM::Transport::Message
        def type        = 'llm.fleet.error'
        def routing_key = @options[:reply_to]
        def priority    = 0
        def encrypt?    = false

        def publish(_options = @options); end

        private

        def message_id_prefix = 'err'
      end
    end
  end
end

require 'legion/extensions/ollama'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end

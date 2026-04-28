# frozen_string_literal: true

require 'legion/extensions/ollama/transport/exchanges/llm_registry'

module Legion
  module Extensions
    module Ollama
      module Transport
        module Messages
          # Publishes lex-llm RegistryEvent envelopes to the llm.registry exchange.
          class RegistryEvent < Legion::Transport::Message
            def initialize(event:, **options)
              envelope = event.to_h
              super(**envelope.merge(options))
            end

            def exchange
              Transport::Exchanges::LlmRegistry
            end

            def routing_key
              @options[:routing_key] || "llm.registry.#{@options.fetch(:event_type)}"
            end

            def type
              'llm.registry.event'
            end

            def app_id
              'lex-ollama'
            end

            def persistent
              false
            end
          end
        end
      end
    end
  end
end

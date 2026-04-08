# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Messages
          # Published back to the caller's reply_to queue after a fleet request is processed.
          # Uses the default RabbitMQ exchange (direct, empty string) with reply_to as routing key,
          # which is standard for RPC-style reply routing.
          class LlmResponse < Legion::Transport::Message
            def routing_key
              @options[:reply_to]
            end

            def exchange
              Legion::Transport::Exchanges::Agent
            end

            def encrypt?
              false
            end

            def message
              {
                correlation_id: @options[:correlation_id],
                result:         @options[:result],
                usage:          @options[:usage],
                model:          @options[:model],
                provider:       'ollama',
                status:         @options[:status] || 200
              }
            end
          end
        end
      end
    end
  end
end

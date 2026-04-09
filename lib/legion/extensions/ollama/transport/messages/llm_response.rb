# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Messages
          # Published back to the caller's reply_to queue after a fleet request is processed.
          #
          # Inherits Legion::LLM::Fleet::Response which:
          #   - sets type: 'llm.fleet.response'
          #   - sets routing_key to @options[:reply_to]
          #   - publishes via AMQP default exchange ('')
          #   - propagates message_context into body and headers
          #   - generates message_id with 'resp_' prefix
          #
          # This class only overrides app_id so audit records and the wire protocol
          # correctly identify lex-ollama as the worker component.
          class LlmResponse < Legion::LLM::Fleet::Response
            def app_id
              'lex-ollama'
            end
          end
        end
      end
    end
  end
end

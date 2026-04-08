# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Runners
        # Fleet runner — handles inbound AMQP LLM request messages and dispatches
        # them to the appropriate Ollama::Client method based on request_type.
        #
        # Called by Actor::ModelWorker with use_runner? = false, meaning the actor
        # calls this module directly rather than going through Legion::Runner.
        module Fleet
          module_function

          # Primary entry point called by the subscription actor.
          #
          # @param model [String] Ollama model name, e.g. "nomic-embed-text"
          # @param request_type [String] "chat", "embed", or "generate"
          # @param reply_to [String, nil] routing key for the reply queue (RPC pattern)
          # @param correlation_id [String, nil] echoed back in the reply for caller matching
          # @param payload [Hash] remaining message keys passed through to the Ollama client
          def handle_request(model:, request_type: 'chat', reply_to: nil,
                             correlation_id: nil, **payload)
            result = dispatch(model: model, request_type: request_type, **payload)
            publish_reply(reply_to, correlation_id, result.merge(model: model)) if reply_to
            result
          end

          def dispatch(model:, request_type:, **payload)
            ollama = Legion::Extensions::Ollama::Client.new

            case request_type.to_s
            when 'embed'
              input = payload[:input] || payload[:text]
              ollama.embed(model: model, input: input,
                           **payload.slice(:truncate, :options, :keep_alive, :dimensions))
            when 'generate'
              ollama.generate(model: model, prompt: payload[:prompt],
                              **payload.slice(:images, :format, :options, :system, :keep_alive))
            else
              # 'chat' and any unrecognised type falls through to chat
              ollama.chat(model: model, messages: payload[:messages],
                          **payload.slice(:tools, :format, :options, :keep_alive, :think))
            end
          rescue StandardError => e
            { result: nil, usage: {}, status: 500, error: e.message }
          end

          def publish_reply(reply_to, correlation_id, result)
            return unless defined?(Legion::Transport)

            Transport::Messages::LlmResponse.new(
              reply_to:       reply_to,
              correlation_id: correlation_id,
              **result
            ).publish
          rescue StandardError
            # Never let a broken reply pipeline kill the consumer ack path.
            nil
          end

          private :dispatch, :publish_reply
        end
      end
    end
  end
end

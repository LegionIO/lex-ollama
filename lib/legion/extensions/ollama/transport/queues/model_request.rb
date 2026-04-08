# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Queues
          # Parametric queue — one instance per (request_type, model) tuple.
          #
          # queue_name mirrors the routing key exactly so bindings are self-documenting
          # in the RabbitMQ management UI, e.g.:
          #   llm.request.ollama.embed.nomic-embed-text
          #   llm.request.ollama.chat.qwen3.5.27b
          class ModelRequest < Legion::Transport::Queue
            def initialize(request_type:, model:, **)
              @request_type = request_type.to_s
              @model        = sanitise_model(model)
              super(**)
            end

            def queue_name
              "llm.request.ollama.#{@request_type}.#{@model}"
            end

            def queue_options
              { durable: true, arguments: { 'x-queue-type': 'quorum' } }
            end

            private

            # Project convention: use dots as the only word separator in routing keys
            # so queue names stay visually consistent (dots are the AMQP topic separator).
            # e.g. "qwen3.5:27b" → "qwen3.5.27b"
            def sanitise_model(name)
              name.to_s.tr(':', '.')
            end
          end
        end
      end
    end
  end
end

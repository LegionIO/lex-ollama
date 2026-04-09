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
          #
          # Queue strategy:
          #   - classic (not quorum): quorum queues cannot be auto-delete
          #   - auto_delete: true — queue deletes when last consumer disconnects + queue empties,
          #     enabling basic.return feedback to publishers via mandatory: true
          #   - x-max-priority: 10 — must be a queue argument at declaration time for classic
          #     queues; policies handle max-length and overflow externally
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
              {
                durable:     false,
                auto_delete: true,
                arguments:   { 'x-max-priority' => 10 }
              }
            end

            # Disable dead-letter exchange provisioning. The base class
            # default_options always adds x-dead-letter-exchange when
            # dlx_enabled returns true. Fleet queues are ephemeral
            # (auto-delete) and must not provision persistent DLX queues.
            def dlx_enabled
              false
            end

            private

            def sanitise_model(name)
              name.to_s.tr(':', '.')
            end
          end
        end
      end
    end
  end
end

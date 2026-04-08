# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Actor
        # Subscription actor that listens on a model-scoped queue and forwards
        # inbound LLM request messages to Runners::Fleet#handle_request.
        #
        # One instance is created per (request_type, model) entry in settings:
        #
        #   legion:
        #     ollama:
        #       subscriptions:
        #         - type: embed
        #           model: nomic-embed-text
        #         - type: chat
        #           model: "qwen3.5:27b"
        #
        # The queue name and routing key both follow the schema:
        #   llm.request.ollama.<type>.<model>
        # where model colons are converted to dots (AMQP topic word separator).
        class ModelWorker < Legion::Extensions::Actors::Subscription
          attr_reader :request_type, :model_name

          def initialize(request_type:, model:, **)
            @request_type = request_type.to_s
            @model_name   = model.to_s
            super(**)
          end

          def runner_class
            Legion::Extensions::Ollama::Runners::Fleet
          end

          def runner_function
            'handle_request'
          end

          # Bypass Legion::Runner — call the runner module directly so we don't
          # need a task record in the database for every LLM inference hop.
          def use_runner?
            false
          end

          # Override queue to return a model-scoped queue bound with the precise
          # routing key for this worker's (type, model) pair.
          def queue
            @queue ||= build_and_bind_queue
          end

          # Enrich every inbound message with the worker's own request_type and model
          # so Runners::Fleet#handle_request always has them, even if the sender omitted them.
          def process_message(payload, metadata, delivery_info)
            msg = super
            msg[:request_type] ||= @request_type
            msg[:model]        ||= @model_name
            msg
          end

          private

          def build_and_bind_queue
            sanitised_model = @model_name.tr(':', '.')
            routing_key     = "llm.request.ollama.#{@request_type}.#{sanitised_model}"

            queue_obj = Transport::Queues::ModelRequest.new(
              request_type: @request_type,
              model:        @model_name
            )
            exchange_obj = Transport::Exchanges::LlmRequest.new
            queue_obj.bind(exchange_obj, routing_key: routing_key)
            queue_obj
          end
        end
      end
    end
  end
end

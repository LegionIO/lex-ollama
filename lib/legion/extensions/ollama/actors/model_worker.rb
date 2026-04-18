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
        #       fleet:
        #         consumer_priority: 10
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

          # prefetch(1) is required for consumer priority to work correctly:
          # without it, a high-priority consumer can hold multiple messages while
          # lower-priority consumers sit idle. With prefetch=1, each consumer
          # completes one message before RabbitMQ delivers the next, and priority
          # determines which idle consumer gets it.
          def prefetch
            1
          end

          # Consumer priority from settings. Tells RabbitMQ to prefer this consumer
          # over lower-priority ones on the same queue when multiple consumers are idle.
          # Standard scale: GPU server = 10, Mac Studio = 5, developer laptop = 1.
          # Defaults to 0 (equal priority) if not configured.
          def consumer_priority
            settings.dig(:fleet, :consumer_priority) || 0
          end

          # Subscribe options include x-priority argument so RabbitMQ can honour
          # consumer priority when dispatching to competing consumers.
          def subscribe_options
            base = begin
              super
            rescue NoMethodError
              {}
            end
            base.merge(arguments: { 'x-priority' => consumer_priority })
          end

          # Returns a queue CLASS (not instance) bound to the llm.request exchange
          # with the routing key for this worker's (type, model) pair.
          # The Subscription base class calls queue.new in initialize, so this must
          # return a class, not an instance.
          def queue
            @queue ||= build_queue_class
          end

          # Enrich every inbound message with the worker's own request_type and model
          # so Runners::Fleet#handle_request always has them, even if the sender omitted
          # them. Also defaults message_context to {} if absent.
          def process_message(payload, metadata, delivery_info)
            msg = super
            msg[:request_type]    ||= @request_type
            msg[:model]           ||= @model_name
            msg[:message_context] ||= {}
            msg
          end

          private

          def build_queue_class
            sanitised_model = @model_name.tr(':', '.')
            routing_key     = "llm.request.ollama.#{@request_type}.#{sanitised_model}"
            exchange_class  = Transport::Exchanges::LlmRequest

            Class.new(Legion::Transport::Queue) do
              define_method(:queue_name) { routing_key }
              define_method(:queue_options) do
                { durable: false, auto_delete: true, arguments: { 'x-max-priority' => 10 } }
              end
              define_method(:dlx_enabled) { false }
              define_method(:initialize) do
                super()
                bind(exchange_class.new, routing_key: routing_key)
              end
            end
          end
        end
      end
    end
  end
end

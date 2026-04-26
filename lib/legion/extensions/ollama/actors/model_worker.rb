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
        # The queue name and routing key both follow shared fleet lane schemas:
        #   llm.fleet.embed.<model>
        #   llm.fleet.inference.<model>.ctx<context_window>
        # when an inference context window is known.
        class ModelWorker < Legion::Extensions::Actors::Subscription
          attr_reader :request_type, :model_name, :context_window

          def initialize(request_type:, model:, context_window: nil, **)
            @request_type    = request_type.to_s
            @model_name      = model.to_s
            @context_window  = context_window&.to_i
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
            setting_value(fleet_settings, :consumer_priority) || 0
          end

          def queue_expires_ms
            setting_value(fleet_settings, :queue_expires_ms) || 60_000
          end

          def message_ttl_ms
            setting_value(fleet_settings, :message_ttl_ms) || 120_000
          end

          def queue_max_length
            setting_value(fleet_settings, :queue_max_length) || 100
          end

          def delivery_limit
            setting_value(fleet_settings, :delivery_limit) || 3
          end

          def consumer_ack_timeout_ms
            setting_value(fleet_settings, :consumer_ack_timeout_ms) || 300_000
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

          # Returns a queue CLASS (not instance) bound to the llm.fleet exchange
          # with the routing key for this worker's model offering lane.
          # The Subscription base class calls queue.new in initialize, so this must
          # return a class, not an instance.
          def queue
            @queue ||= build_queue_class
          end

          def self.queue_class_for(request_type:, model:, context_window: nil, queue_config: {})
            worker = allocate
            worker.instance_variable_set(:@request_type, request_type.to_s)
            worker.instance_variable_set(:@model_name, model.to_s)
            worker.instance_variable_set(:@context_window, context_window&.to_i)
            worker.send(:build_queue_class, queue_config)
          end

          def self.fallback_queue_options(settings)
            {
              durable:     true,
              auto_delete: false,
              arguments:   {
                'x-queue-type'           => 'quorum',
                'x-queue-leader-locator' => 'balanced',
                'x-expires'              => settings.fetch(:queue_expires_ms),
                'x-message-ttl'          => settings.fetch(:message_ttl_ms),
                'x-overflow'             => 'reject-publish',
                'x-max-length'           => settings.fetch(:queue_max_length),
                'x-delivery-limit'       => settings.fetch(:delivery_limit),
                'x-consumer-timeout'     => settings.fetch(:consumer_ack_timeout_ms)
              }
            }
          end

          def routing_key
            parts = ['llm.fleet', lane_kind, sanitized_model]
            parts << "ctx#{@context_window}" if lane_kind == 'inference' && @context_window
            parts.join('.')
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

          def build_queue_class(queue_config = {})
            lane_key        = routing_key
            exchange_class  = Transport::Exchanges::LlmRequest
            queue_settings  = {
              queue_expires_ms:        queue_expires_ms,
              message_ttl_ms:          message_ttl_ms,
              queue_max_length:        queue_max_length,
              delivery_limit:          delivery_limit,
              consumer_ack_timeout_ms: consumer_ack_timeout_ms
            }.merge((queue_config || {}).compact)

            if defined?(::Legion::Extensions::Llm::Transport::FleetLane)
              return ::Legion::Extensions::Llm::Transport::FleetLane.build_queue_class(
                queue_name:       lane_key,
                exchange_class:   exchange_class,
                routing_key:      lane_key,
                base_queue_class: Legion::Transport::Queue,
                settings:         queue_settings
              )
            end

            queue_options = self.class.fallback_queue_options(queue_settings)

            Class.new(Legion::Transport::Queue) do
              define_method(:queue_name) { lane_key }
              define_method(:queue_options) { queue_options }
              define_method(:dlx_enabled) { false }
              define_method(:initialize) do
                super()
                bind(exchange_class.new, routing_key: lane_key)
              end
            end
          end

          def fleet_settings
            setting_value(settings, :fleet) || {}
          rescue NameError
            {}
          end

          def setting_value(hash, key)
            return nil unless hash.respond_to?(:key?)

            string_key = key.to_s
            return hash[string_key] if hash.key?(string_key)

            hash[key] if hash.key?(key)
          end

          def lane_kind
            %w[embed embedding embeddings].include?(@request_type) ? 'embed' : 'inference'
          end

          def sanitized_model
            @model_name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '').squeeze('-')
          end
        end
      end
    end
  end
end

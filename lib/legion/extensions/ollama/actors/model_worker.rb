# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Actor
        # Fleet actor that listens on a model-scoped queue and forwards
        # inbound LLM request messages to Runners::Fleet#handle_request.
        # Endpoint workers default to explicit basic_get polling so a local
        # one-model-at-a-time device does not reserve messages from every lane.
        # Set legion.ollama.fleet.scheduler to :subscription for GPU/datacenter
        # workers that should use RabbitMQ consumer priority and prefetch.
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
        # Queue names and routing keys follow the shared fleet lane schema:
        #   llm.fleet.embed.<model-slug>
        #   llm.fleet.inference.<model-slug>.ctx<context-window>
        class ModelWorker < Legion::Extensions::Actors::Subscription
          POLLING_SCHEDULERS = %i[basic_get poll polling].freeze
          SUBSCRIPTION_SCHEDULERS = %i[subscribe subscription basic_consume consumer].freeze
          POLL_LOCK = Mutex.new

          attr_reader :request_type, :model_name, :context_window

          def initialize(request_type:, model:, context_window: nil, **)
            @request_type = request_type.to_s
            @model_name   = model.to_s
            @context_window = normalize_context_window(context_window)
            @polling = false
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

          def prepare
            return super unless endpoint_polling?

            @queue = queue.new
            @polling = true
            log.info "[ModelWorker] prepared polling lane #{lane_key}" if defined?(log)
          rescue StandardError => e
            handle_exception(e, level: :fatal)
          end

          def activate
            return super unless endpoint_polling?

            @polling = true
            @poll_task = async.run_basic_get_loop
            log.info "[ModelWorker] activated polling lane #{lane_key}" if defined?(log)
          rescue StandardError => e
            handle_exception(e, level: :fatal)
          end

          def cancel
            @polling = false
            return true unless instance_variable_defined?(:@consumer) && @consumer

            super
          end

          def endpoint_polling?
            scheduler = fleet_scheduler
            return true if POLLING_SCHEDULERS.include?(scheduler)
            return false if SUBSCRIPTION_SCHEDULERS.include?(scheduler)

            settings.dig(:fleet, :endpoint, :enabled) == true
          rescue StandardError
            false
          end

          def lane_key
            @lane_key ||= begin
              parts = ['llm.fleet', lane_kind, model_slug]
              parts << "ctx#{@context_window}" if lane_kind == 'inference' && @context_window
              parts.join('.')
            end
          end

          def run_basic_get_loop
            consecutive_pulls = 0
            while @polling && !shutting_down?
              pulled = POLL_LOCK.synchronize { pull_one_message }
              consecutive_pulls = pulled ? consecutive_pulls + 1 : 0
              sleep(pulled ? post_pull_backoff(consecutive_pulls) : empty_lane_backoff)
            end
          end

          def pull_one_message
            delivery_info, metadata, payload = @queue.pop(manual_ack: manual_ack)
            return false unless delivery_info

            handle_delivery(delivery_info, metadata, payload)
            true
          rescue StandardError => e
            handle_exception(e)
            reject_or_retry(delivery_info, metadata, payload) if manual_ack && delivery_info
            true
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
            routing_key     = lane_key
            exchange_class  = Transport::Exchanges::LlmRequest

            Class.new(Legion::Transport::Queue) do
              define_method(:queue_name) { routing_key }
              define_method(:queue_options) do
                {
                  durable:     true,
                  auto_delete: false,
                  arguments:   {
                    'x-queue-type'           => 'quorum',
                    'x-queue-leader-locator' => 'balanced',
                    'x-expires'              => 60_000,
                    'x-message-ttl'          => 120_000,
                    'x-overflow'             => 'reject-publish',
                    'x-max-length'           => 100,
                    'x-delivery-limit'       => 3,
                    'x-consumer-timeout'     => 300_000
                  }
                }
              end
              define_method(:dlx_enabled) { false }
              define_method(:initialize) do
                super()
                bind(exchange_class.new, routing_key: routing_key)
              end
            end
          end

          def handle_delivery(delivery_info, metadata, payload)
            message = process_message(payload, metadata, delivery_info)
            fn = find_function(message)
            log.debug "[ModelWorker] basic_get message received: #{lex_name}/#{fn}" if defined?(log)

            affinity_result = check_region_affinity(message)
            if affinity_result == :reject
              log.warn '[ModelWorker] nack: region affinity mismatch' if defined?(log)
              @queue.reject(delivery_info.delivery_tag) if manual_ack
              return
            end

            record_cross_region_metric(message) if affinity_result == :remote

            if use_runner?
              dispatch_runner(message, runner_class, fn, check_subtask?, generate_task?)
            else
              runner_class.send(fn, **message)
            end
            @queue.acknowledge(delivery_info.delivery_tag) if manual_ack
          end

          def fleet_scheduler
            (settings.dig(:fleet, :scheduler) || :basic_get).to_sym
          end

          def lane_kind
            @request_type == 'embed' ? 'embed' : 'inference'
          end

          def model_slug
            @model_name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
          end

          def normalize_context_window(value)
            return nil if value.nil? || value.to_s.empty?

            Integer(value)
          rescue ArgumentError, TypeError
            nil
          end

          def empty_lane_backoff
            milliseconds = settings.dig(:fleet, :endpoint, :empty_lane_backoff_ms) || 250
            milliseconds.to_f / 1000.0
          rescue StandardError
            0.25
          end

          def idle_backoff
            milliseconds = settings.dig(:fleet, :endpoint, :idle_backoff_ms) || 1_000
            milliseconds.to_f / 1000.0
          rescue StandardError
            1.0
          end

          def max_consecutive_pulls_per_lane
            Integer(settings.dig(:fleet, :endpoint, :max_consecutive_pulls_per_lane) || 0)
          rescue StandardError
            0
          end

          def post_pull_backoff(consecutive_pulls)
            max_pulls = max_consecutive_pulls_per_lane
            return 0 if max_pulls.zero? || consecutive_pulls < max_pulls

            idle_backoff
          end

          def shutting_down?
            defined?(Legion::Settings) && Legion::Settings.dig(:client, :shutting_down)
          rescue StandardError
            false
          end
        end
      end
    end
  end
end

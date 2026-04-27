# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Actor
        # Polls configured fleet queues with basic_get so endpoint machines choose
        # when they are ready for work instead of holding prefetched messages.
        class EndpointPuller < Legion::Extensions::Actors::Every
          def runner_class
            self.class
          end

          def runner_function
            'action'
          end

          def use_runner?
            false
          end

          def check_subtask?
            false
          end

          def generate_task?
            false
          end

          def enabled?
            fleet_scheduler == :basic_get && endpoint_enabled? && subscriptions.any?
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true)
            false
          end

          def time
            (setting_value(endpoint_settings, :idle_backoff_ms) || 1_000).to_f / 1000
          end

          def action
            return unless enabled?

            now = monotonic_time
            ordered_subscriptions.each do |sub|
              next if lane_backed_off?(sub, now)

              pulled = drain_lane(sub)
              mark_lane_empty(sub) if pulled.zero?
            end
          end

          def ordered_subscriptions
            subscriptions.sort_by do |sub|
              type = sub[:type].to_s
              [embed_type?(type) ? 0 : 1, context_limit(sub), sub[:model].to_s]
            end
          end

          def drain_lane(subscription)
            pulls = 0
            queue = queue_for(subscription)

            loop do
              break if max_consecutive_pulls_per_lane.positive? && pulls >= max_consecutive_pulls_per_lane
              break unless pull_one(queue, subscription)

              pulls += 1
            end
            pulls
          end

          def pull_one(queue, subscription)
            delivery_info, metadata, payload = queue.pop(manual_ack: true)
            return false unless delivery_info

            message = process_payload(payload, metadata, delivery_info, subscription)
            Legion::Extensions::Ollama::Runners::Fleet.handle_request(**message)
            queue.acknowledge(delivery_info.delivery_tag)
            true
          rescue StandardError => e
            handle_exception(e, lex: lex_name, routing_key: delivery_info&.routing_key)
            queue.reject(delivery_info.delivery_tag, requeue: false) if delivery_info
            true
          end

          def queue_for(subscription)
            @queues ||= {}
            @queues[lane_key(subscription)] ||= ModelWorker.queue_class_for(
              request_type:   subscription[:type],
              model:          subscription[:model],
              context_window: finite_context_limit(subscription),
              queue_config:   queue_config
            ).new
          end

          def process_payload(payload, metadata, delivery_info, subscription)
            message = decode_payload(payload, metadata)
            message = message.merge(metadata.headers.transform_keys(&:to_sym)) if metadata&.headers
            message[:routing_key] = delivery_info.routing_key if delivery_info.respond_to?(:routing_key)
            message[:request_type] ||= subscription[:type].to_s
            message[:model] ||= subscription[:model].to_s
            message[:message_context] ||= {}
            message
          end

          def decode_payload(payload, metadata)
            decoded = if metadata&.content_encoding == 'encrypted/cs'
                        Legion::Crypt.decrypt(payload, metadata_header(metadata, :iv))
                      elsif metadata&.content_encoding == 'encrypted/pk'
                        Legion::Crypt.decrypt_from_keypair(metadata_header(metadata, :public_key), payload)
                      else
                        payload
                      end

            if metadata&.content_type == 'application/json'
              Legion::JSON.load(decoded)
            else
              { value: decoded }
            end
          end

          def subscriptions
            configured = setting_value(settings, :subscriptions)
            return [] unless configured.is_a?(Array)

            configured.filter_map do |sub|
              next unless sub.is_a?(Hash)

              normalized = sub.transform_keys(&:to_sym)
              next unless normalized[:type] && normalized[:model]

              normalized
            end
          end

          def queue_config
            {
              queue_expires_ms:        nested_setting(settings, :fleet, :queue_expires_ms),
              message_ttl_ms:          nested_setting(settings, :fleet, :message_ttl_ms),
              queue_max_length:        nested_setting(settings, :fleet, :queue_max_length),
              delivery_limit:          nested_setting(settings, :fleet, :delivery_limit),
              consumer_ack_timeout_ms: nested_setting(settings, :fleet, :consumer_ack_timeout_ms)
            }.compact
          end

          def endpoint_settings
            nested_setting(settings, :fleet, :endpoint) || {}
          end

          def endpoint_enabled?
            setting_value(endpoint_settings, :enabled) == true
          end

          def max_consecutive_pulls_per_lane
            setting_value(endpoint_settings, :max_consecutive_pulls_per_lane) || 0
          end

          def empty_lane_backoff_seconds
            (setting_value(endpoint_settings, :empty_lane_backoff_ms) || 250).to_f / 1000
          end

          def lane_backed_off?(subscription, now)
            (@empty_lanes ||= {}).fetch(lane_key(subscription), 0) > now
          end

          def mark_lane_empty(subscription)
            (@empty_lanes ||= {})[lane_key(subscription)] = monotonic_time + empty_lane_backoff_seconds
          end

          def lane_key(subscription)
            type = subscription[:type]
            model = subscription[:model]
            context = context_limit(subscription)
            context.finite? ? "#{type}:#{model}:ctx#{context}" : "#{type}:#{model}"
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def fleet_scheduler
            (nested_setting(settings, :fleet, :scheduler) || :basic_get).to_sym
          end

          def context_limit(subscription)
            raw = setting_value(subscription, :max_context_size) ||
                  setting_value(subscription, :context_window) ||
                  setting_value(subscription, :max_input_tokens) ||
                  setting_value(subscription, :context) ||
                  setting_value(subscription, :ctx)
            Integer(raw || Float::INFINITY)
          rescue ArgumentError, TypeError, FloatDomainError
            Float::INFINITY
          end

          def finite_context_limit(subscription)
            context = context_limit(subscription)
            context.finite? ? context : nil
          end

          def embed_type?(type)
            %w[embed embedding embeddings].include?(type)
          end

          def metadata_header(metadata, key)
            setting_value(metadata&.headers || {}, key)
          end

          def nested_setting(hash, *keys)
            keys.reduce(hash) do |current, key|
              return nil unless current.respond_to?(:key?)

              setting_value(current, key)
            end
          end

          def setting_value(hash, key)
            return nil unless hash.respond_to?(:key?)

            string_key = key.to_s
            return hash[string_key] if hash.key?(string_key)

            hash[key] if hash.key?(key)
          end
        end
      end
    end
  end
end

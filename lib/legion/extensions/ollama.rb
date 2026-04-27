# frozen_string_literal: true

require 'legion/extensions/ollama/version'
require 'legion/extensions/ollama/helpers/client'
require 'legion/extensions/ollama/helpers/errors'
require 'legion/extensions/ollama/helpers/usage'
require 'legion/extensions/ollama/runners/completions'
require 'legion/extensions/ollama/runners/chat'
require 'legion/extensions/ollama/runners/models'
require 'legion/extensions/ollama/runners/embeddings'
require 'legion/extensions/ollama/runners/blobs'
require 'legion/extensions/ollama/runners/s3_models'
require 'legion/extensions/ollama/runners/version'
require 'legion/extensions/ollama/runners/fleet'
require 'legion/extensions/ollama/client'

begin
  require 'legion/extensions/llm'
rescue LoadError
  nil
end

# Fleet transport and actor wiring — only loaded when Legion::Extensions::Core is present
# so the gem still works as a standalone HTTP client without any AMQP runtime.
if Legion::Extensions.const_defined?(:Core, false)
  require 'legion/extensions/ollama/transport/exchanges/llm_request'
  require 'legion/extensions/ollama/transport/messages/llm_response'
  require 'legion/extensions/ollama/transport'
  require 'legion/extensions/ollama/actors/model_worker'
  require 'legion/extensions/ollama/actors/endpoint_puller'
  require 'legion/extensions/ollama/actors/model_sync'
end

module Legion
  module Extensions
    module Ollama
      extend Legion::Extensions::Core if Legion::Extensions.const_defined?(:Core, false)

      def self.default_settings
        {
          s3:    {},
          fleet: {
            consumer_priority:       0,
            scheduler:               :basic_get,
            queue_expires_ms:        60_000,
            message_ttl_ms:          120_000,
            queue_max_length:        100,
            delivery_limit:          3,
            consumer_ack_timeout_ms: 300_000,
            endpoint:                {
              enabled:                        false,
              empty_lane_backoff_ms:          250,
              idle_backoff_ms:                1_000,
              max_consecutive_pulls_per_lane: 0,
              accept_when:                    []
            }
          }
        }
      end

      # Called by the framework during autobuild. Runs normal actor discovery,
      # then replaces the single ModelWorker entry with one concrete subclass
      # per subscription entry in settings (each has a zero-arg initialize).
      def self.build_actors
        super
        @actors.delete(:model_worker)

        subs = setting_value(settings, :subscriptions)
        valid_subscriptions = valid_fleet_subscriptions(subs)
        endpoint_configured = fleet_scheduler == :basic_get &&
                              nested_setting(settings, :fleet, :endpoint, :enabled) == true &&
                              valid_subscriptions.any?
        @actors.delete(:endpoint_puller) unless endpoint_configured

        return unless subs.is_a?(Array)
        return if fleet_scheduler == :basic_get

        subs.each do |sub|
          request_type   = setting_value(sub, :type)&.to_s
          model          = setting_value(sub, :model)&.to_s
          limits         = setting_value(sub, :limits) || {}
          context_window = setting_value(sub, :context_window) ||
                           setting_value(limits, :context_window)
          next unless request_type && model

          actor_name   = :"model_worker_#{request_type}_#{model.tr(':.', '__')}"
          worker_class = Class.new(Legion::Extensions::Ollama::Actor::ModelWorker) do
            define_method(:initialize) do
              super(request_type: request_type, model: model, context_window: context_window)
            end
          end

          @actors[actor_name] = {
            extension:      'lex-ollama',
            extension_name: :ollama,
            actor_name:     actor_name,
            actor_class:    worker_class,
            type:           'literal'
          }
        end
      end

      def self.fleet_scheduler
        (nested_setting(settings, :fleet, :scheduler) || :basic_get).to_sym
      end

      def self.valid_fleet_subscriptions(subscriptions)
        return [] unless subscriptions.is_a?(Array)

        subscriptions.select do |sub|
          setting_value(sub, :type) && setting_value(sub, :model)
        end
      end

      def self.setting_value(hash, key)
        return nil unless hash.respond_to?(:key?)

        string_key = key.to_s
        return hash[string_key] if hash.key?(string_key)

        hash[key] if hash.key?(key)
      end

      def self.nested_setting(hash, *keys)
        keys.reduce(hash) do |current, key|
          return nil unless current.respond_to?(:key?)

          setting_value(current, key)
        end
      end
    end
  end
end

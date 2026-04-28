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

# Fleet transport and actor wiring — only loaded when Legion::Extensions::Core is present
# so the gem still works as a standalone HTTP client without any AMQP runtime.
if Legion::Extensions.const_defined?(:Core, false)
  require 'legion/extensions/ollama/transport/exchanges/llm_request'
  require 'legion/extensions/ollama/transport/messages/llm_response'
  require 'legion/extensions/ollama/transport'
  require 'legion/extensions/ollama/actors/model_worker'
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
            scheduler: :basic_get,
            endpoint:  {
              enabled:                        false,
              empty_lane_backoff_ms:          250,
              idle_backoff_ms:                1_000,
              max_consecutive_pulls_per_lane: 0
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

        subs = settings[:subscriptions]
        return unless subs.is_a?(Array)

        sorted_subscriptions(subs).each do |sub|
          request_type = sub[:type]&.to_s
          model        = sub[:model]&.to_s
          context_window = context_window_for(sub)
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

      def self.sorted_subscriptions(subscriptions)
        subscriptions.sort_by do |sub|
          type = sub[:type].to_s
          [
            type == 'embed' ? 0 : 1,
            context_window_for(sub) || Float::INFINITY,
            sub[:model].to_s
          ]
        end
      end

      def self.context_window_for(subscription)
        raw = subscription[:context_window] ||
              subscription[:max_context] ||
              subscription[:max_input_tokens] ||
              subscription.dig(:limits, :context_window) ||
              subscription.dig(:limits, :max_input_tokens)
        return nil if raw.nil? || raw.to_s.empty?

        Integer(raw)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end

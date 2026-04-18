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
          fleet: {}
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

        subs.each do |sub|
          request_type = sub[:type]&.to_s
          model        = sub[:model]&.to_s
          next unless request_type && model

          actor_name   = :"model_worker_#{request_type}_#{model.tr(':.', '__')}"
          worker_class = Class.new(Legion::Extensions::Ollama::Actor::ModelWorker) do
            define_method(:initialize) { super(request_type: request_type, model: model) }
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
    end
  end
end

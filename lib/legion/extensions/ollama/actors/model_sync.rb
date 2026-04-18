# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Actor
        # Once actor — fires 5s after extension load and calls
        # Runners::S3Models#sync_configured_models to pull any configured
        # default models from S3 that are not already present locally.
        #
        # All download logic lives in the runner. This actor is only the trigger.
        class ModelSync < Legion::Extensions::Actors::Once
          def delay
            5.0
          end

          def runner_class
            Legion::Extensions::Ollama::Runners::S3Models
          end

          def runner_function
            'sync_configured_models'
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
            s3_cfg = settings[:s3]
            models = settings[:default_models]
            s3_cfg.is_a?(Hash) && !s3_cfg[:bucket].nil? && models.is_a?(Array) && !models.empty?
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true)
            false
          end
        end
      end
    end
  end
end

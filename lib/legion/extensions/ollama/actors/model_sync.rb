# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Actor
        # Once actor — runs once shortly after extension load.
        # Reads legion.ollama.s3 and legion.ollama.default_models from settings
        # and calls import_from_s3 for any model not already present locally.
        #
        # Settings example:
        #   {
        #     "legion": {
        #       "ollama": {
        #         "s3": {
        #           "bucket": "legion",
        #           "prefix": "ollama/models",
        #           "endpoint": "https://s3.example.internal"
        #         },
        #         "default_models": ["qwen3.5:4b", "nomic-embed-text:latest"]
        #       }
        #     }
        #   }
        class ModelSync < Legion::Extensions::Actors::Once
          include Legion::Logging::Helper

          # Run 5 seconds after extension load to allow the rest of startup to complete.
          def delay
            5.0
          end

          def use_runner?
            false
          end

          def runner_class
            self.class
          end

          def enabled?
            return false unless defined?(Legion::Settings)

            models = Legion::Settings.dig(:ollama, :default_models)
            s3_cfg = Legion::Settings.dig(:ollama, :s3)
            models.is_a?(Array) && !models.empty? && s3_cfg.is_a?(Hash) && s3_cfg[:bucket]
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true)
            false
          end

          def manual
            models = Legion::Settings.dig(:ollama, :default_models) || []
            s3_cfg = Legion::Settings.dig(:ollama, :s3)
            bucket = s3_cfg[:bucket]
            s3_opts = s3_cfg.except(:bucket)

            client = Object.new.extend(Legion::Extensions::Ollama::Runners::S3Models)
            models_path = ENV.fetch('OLLAMA_MODELS', File.join(Dir.home, '.ollama', 'models'))

            models.each do |model|
              if model_present_locally?(model, models_path)
                log.debug "[ModelSync] #{model} already present locally, skipping"
                next
              end

              log.info "[ModelSync] importing #{model} from S3"
              result = client.import_from_s3(model: model, bucket: bucket, models_path: models_path, **s3_opts)
              if result[:status] == 200
                log.info "[ModelSync] imported #{model} (blobs_downloaded=#{result[:blobs_downloaded]}, blobs_skipped=#{result[:blobs_skipped]})"
              else
                log.warn "[ModelSync] failed to import #{model}: #{result.inspect}"
              end
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, model: model)
            end
          end

          private

          def model_present_locally?(model, models_path)
            name, tag = model.split(':')
            tag ||= 'latest'
            manifest = File.join(models_path, 'manifests', 'registry.ollama.ai', 'library', name, tag)
            File.exist?(manifest)
          end
        end
      end
    end
  end
end

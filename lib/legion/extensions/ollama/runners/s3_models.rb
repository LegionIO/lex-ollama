# frozen_string_literal: true

require 'legion/extensions/s3/client'
require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module S3Models
          extend Legion::Extensions::Ollama::Helpers::Client

          OLLAMA_REGISTRY_PREFIX = 'manifests/registry.ollama.ai/library'

          def default_models_path
            ENV.fetch('OLLAMA_MODELS', File.join(Dir.home, '.ollama', 'models'))
          end

          def s3_model_client(**s3_opts)
            Legion::Extensions::S3::Client.new(**s3_opts)
          end

          def parse_model_ref(model)
            parts = model.split(':')
            { name: parts[0], tag: parts[1] || 'latest' }
          end

          def list_s3_models(bucket:, prefix: 'ollama/models', **s3_opts)
            s3 = s3_model_client(**s3_opts)
            manifest_prefix = "#{prefix}/#{OLLAMA_REGISTRY_PREFIX}/"
            resp = s3.list_objects(bucket: bucket, prefix: manifest_prefix, max_keys: 1000)

            models = resp[:objects].filter_map do |obj|
              relative = obj[:key].delete_prefix(manifest_prefix)
              parts = relative.split('/')
              next unless parts.length == 2

              { name: parts[0], tag: parts[1] }
            end

            { models: models, status: 200 }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

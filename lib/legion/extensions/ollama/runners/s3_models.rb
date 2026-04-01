# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'legion/extensions/s3/client'
require 'legion/extensions/ollama/helpers/client'
require 'legion/extensions/ollama/helpers/errors'

module Legion
  module Extensions
    module Ollama
      module Runners
        module S3Models
          extend Legion::Extensions::Ollama::Helpers::Client

          OLLAMA_REGISTRY_PREFIX = 'manifests/registry.ollama.ai/library'

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

          def import_from_s3(model:, bucket:, prefix: 'ollama/models', models_path: nil, **s3_opts)
            s3 = s3_model_client(**s3_opts)
            path = models_path || default_models_path
            ref = parse_model_ref(model)
            name = ref[:name]
            tag  = ref[:tag]

            manifest_key = "#{prefix}/#{OLLAMA_REGISTRY_PREFIX}/#{name}/#{tag}"
            manifest_resp = s3.get_object(bucket: bucket, key: manifest_key)
            manifest_body = manifest_resp[:body]
            manifest_data = JSON.parse(manifest_body)

            digests = []
            digests << manifest_data['config'].slice('digest', 'size')
            digests.concat(manifest_data['layers'].map { |l| l.slice('digest', 'size') })

            blobs_downloaded = 0
            blobs_skipped    = 0

            digests.each do |entry|
              digest = entry['digest']
              expected_size = entry['size']
              blob_filename = digest.sub(':', '-')
              local_path    = File.join(path, 'blobs', blob_filename)

              if File.exist?(local_path) && File.size(local_path) == expected_size
                blobs_skipped += 1
                next
              end

              blob_key  = "#{prefix}/blobs/#{blob_filename}"
              blob_resp = s3.get_object(bucket: bucket, key: blob_key)
              FileUtils.mkdir_p(File.dirname(local_path))
              File.binwrite(local_path, blob_resp[:body])
              blobs_downloaded += 1
            end

            manifest_path = File.join(path, 'manifests', 'registry.ollama.ai', 'library', name, tag)
            FileUtils.mkdir_p(File.dirname(manifest_path))
            File.binwrite(manifest_path, manifest_body)

            { result: true, model: model, blobs_downloaded: blobs_downloaded, blobs_skipped: blobs_skipped,
              status: 200 }
          end

          def sync_from_s3(model:, bucket:, prefix: 'ollama/models', host: nil, models_path: nil, **s3_opts)
            ollama_opts = host ? { host: host } : {}
            path = models_path || default_models_path
            s3 = s3_model_client(**s3_opts)
            ref = parse_model_ref(model)
            name = ref[:name]
            tag  = ref[:tag]
            model_ref = "#{name}:#{tag}"

            manifest_key = "#{prefix}/#{OLLAMA_REGISTRY_PREFIX}/#{name}/#{tag}"
            manifest_resp = s3.get_object(bucket: bucket, key: manifest_key)
            manifest_data = JSON.parse(manifest_resp[:body])

            digests = []
            digests << manifest_data['config']['digest']
            digests.concat(manifest_data['layers'].map { |l| l['digest'] })

            blobs_pushed = 0
            blobs_skipped = 0

            digests.each do |digest|
              if check_blob(digest: digest, **ollama_opts)[:result]
                blobs_skipped += 1
                next
              end

              blob_filename = digest.sub(':', '-')
              blob_resp = s3.get_object(bucket: bucket, key: "#{prefix}/blobs/#{blob_filename}")
              push_blob(digest: digest, body: blob_resp[:body], **ollama_opts)
              blobs_pushed += 1
            end

            manifest_path = File.join(path, 'manifests', 'registry.ollama.ai', 'library', name, tag)
            FileUtils.mkdir_p(File.dirname(manifest_path))
            File.binwrite(manifest_path, manifest_resp[:body])

            { result: true, model: model_ref, blobs_pushed: blobs_pushed, blobs_skipped: blobs_skipped,
              status: 200 }
          end

          def import_default_models(default_models:, bucket:, **)
            results = default_models.map do |model|
              import_from_s3(model: model, bucket: bucket, **)
            end

            { result: results, status: 200 }
          end

          private

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

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

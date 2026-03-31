# frozen_string_literal: true

require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Models
          extend Legion::Extensions::Ollama::Helpers::Client

          def create_model(model:, from: nil, files: nil, system: nil, stream: false, quantize: nil, **)
            body = { model: model, from: from, files: files, system: system,
                     stream: stream, quantize: quantize }.compact
            response = client(**).post('/api/create', body)
            { result: response.body, status: response.status }
          end

          def list_models(**)
            response = client(**).get('/api/tags')
            { result: response.body, status: response.status }
          end

          def show_model(model:, verbose: nil, **)
            body = { model: model, verbose: verbose }.compact
            response = client(**).post('/api/show', body)
            { result: response.body, status: response.status }
          end

          def copy_model(source:, destination:, **)
            body = { source: source, destination: destination }
            response = client(**).post('/api/copy', body)
            { result: response.status == 200, status: response.status }
          end

          def delete_model(model:, **)
            body = { model: model }
            response = client(**).delete('/api/delete') do |req|
              req.body = body
            end
            { result: response.status == 200, status: response.status }
          end

          def pull_model(model:, insecure: nil, stream: false, **)
            body = { model: model, insecure: insecure, stream: stream }.compact
            response = client(**).post('/api/pull', body)
            { result: response.body, status: response.status }
          end

          def push_model(model:, insecure: nil, stream: false, **)
            body = { model: model, insecure: insecure, stream: stream }.compact
            response = client(**).post('/api/push', body)
            { result: response.body, status: response.status }
          end

          def list_running(**)
            response = client(**).get('/api/ps')
            { result: response.body, status: response.status }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

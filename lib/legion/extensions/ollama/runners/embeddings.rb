# frozen_string_literal: true

require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Embeddings
          extend Legion::Extensions::Ollama::Helpers::Client

          def embed(model:, input:, truncate: nil, options: nil, keep_alive: nil, dimensions: nil, **)
            body = { model: model, input: input, truncate: truncate, options: options,
                     keep_alive: keep_alive, dimensions: dimensions }.compact
            response = client(**).post('/api/embed', body)
            { result: response.body, status: response.status }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

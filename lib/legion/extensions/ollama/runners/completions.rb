# frozen_string_literal: true

require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Completions
          extend Legion::Extensions::Ollama::Helpers::Client

          def generate(model:, prompt: nil, images: nil, format: nil, options: nil, system: nil, stream: false, keep_alive: nil, **)
            body = { model: model, prompt: prompt, images: images, format: format, options: options,
                     system: system, stream: stream, keep_alive: keep_alive }.compact
            response = client(**).post('/api/generate', body)
            { result: response.body, status: response.status }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

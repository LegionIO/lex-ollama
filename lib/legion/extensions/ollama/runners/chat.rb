# frozen_string_literal: true

require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Chat
          extend Legion::Extensions::Ollama::Helpers::Client

          def chat(model:, messages:, tools: nil, format: nil, options: nil, stream: false, keep_alive: nil, think: nil, **)
            body = { model: model, messages: messages, tools: tools, format: format, options: options,
                     stream: stream, keep_alive: keep_alive, think: think }.compact
            response = client(**).post('/api/chat', body)
            { result: response.body, status: response.status }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

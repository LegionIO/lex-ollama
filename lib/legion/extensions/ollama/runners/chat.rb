# frozen_string_literal: true

require 'json'
require 'legion/extensions/ollama/helpers/client'
require 'legion/extensions/ollama/helpers/errors'
require 'legion/extensions/ollama/helpers/usage'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Chat
          extend Legion::Extensions::Ollama::Helpers::Client

          def chat(model:, messages:, tools: nil, format: nil, options: nil, stream: false, keep_alive: nil, think: nil, **)
            body = { model: model, messages: messages, tools: tools, format: format, options: options,
                     stream: stream, keep_alive: keep_alive, think: think }.compact
            response = Helpers::Errors.with_retry { client(**).post('/api/chat', body) }
            { result: response.body, usage: Helpers::Usage.from_response(response.body), status: response.status }
          end

          def chat_stream(model:, messages:, tools: nil, format: nil, options: nil, keep_alive: nil, think: nil, **, &block)
            body = { model: model, messages: messages, tools: tools, format: format, options: options,
                     stream: true, keep_alive: keep_alive, think: think }.compact
            accumulated = +''
            final_response = nil
            buffer = +''

            Helpers::Errors.with_retry do
              streaming_client(**).post('/api/chat', body) do |req|
                req.options.on_data = proc do |chunk, _size|
                  buffer << chunk
                  while (idx = buffer.index("\n"))
                    line = buffer.slice!(0, idx + 1).strip
                    next if line.empty?

                    parsed = ::JSON.parse(line)
                    if parsed['done']
                      final_response = parsed
                      block&.call({ type: :done, data: parsed })
                    else
                      text = parsed.dig('message', 'content') || ''
                      accumulated << text
                      block&.call({ type: :delta, text: text })
                    end
                  end
                end
              end
            end

            { result: accumulated, usage: Helpers::Usage.from_response(final_response), status: 200 }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

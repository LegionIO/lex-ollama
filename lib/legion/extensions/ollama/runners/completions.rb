# frozen_string_literal: true

require 'json'
require 'legion/extensions/ollama/helpers/client'
require 'legion/extensions/ollama/helpers/errors'
require 'legion/extensions/ollama/helpers/usage'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Completions
          extend Legion::Extensions::Ollama::Helpers::Client

          def generate(model:, prompt: nil, images: nil, format: nil, options: nil, system: nil, stream: false, keep_alive: nil, **)
            body = { model: model, prompt: prompt, images: images, format: format, options: options,
                     system: system, stream: stream, keep_alive: keep_alive }.compact
            response = Helpers::Errors.with_retry { client(**).post('/api/generate', body) }
            { result: response.body, usage: Helpers::Usage.from_response(response.body), status: response.status }
          end

          def generate_stream(model:, prompt: nil, images: nil, format: nil, options: nil, system: nil, keep_alive: nil, **, &block)
            body = { model: model, prompt: prompt, images: images, format: format, options: options,
                     system: system, stream: true, keep_alive: keep_alive }.compact
            accumulated = +''
            final_response = nil
            buffer = +''

            Helpers::Errors.with_retry do
              streaming_client(**).post('/api/generate', body) do |req|
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
                      text = parsed['response'] || ''
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

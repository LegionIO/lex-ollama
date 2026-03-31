# frozen_string_literal: true

require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Blobs
          extend Legion::Extensions::Ollama::Helpers::Client

          def check_blob(digest:, **)
            response = client(**).head("/api/blobs/#{digest}")
            { result: response.status == 200, status: response.status }
          end

          def push_blob(digest:, body:, **)
            response = client(**).post("/api/blobs/#{digest}") do |req|
              req.headers['Content-Type'] = 'application/octet-stream'
              req.body = body
            end
            { result: response.status == 201, status: response.status }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

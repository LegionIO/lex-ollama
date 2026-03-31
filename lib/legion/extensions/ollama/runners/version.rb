# frozen_string_literal: true

require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module Version
          extend Legion::Extensions::Ollama::Helpers::Client

          def server_version(**)
            response = client(**).get('/api/version')
            { result: response.body, status: response.status }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end

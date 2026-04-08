# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Exchanges
          class LlmRequest < Legion::Transport::Exchange
            def exchange_name
              'llm.request'
            end

            def default_type
              'topic'
            end
          end
        end
      end
    end
  end
end

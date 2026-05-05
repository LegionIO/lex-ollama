# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Exchanges
          # Topic exchange for provider availability events consumed by LLM routing registries.
          class LlmRegistry < Legion::Transport::Exchange
            def exchange_name
              'llm.registry'
            end
          end
        end
      end
    end
  end
end

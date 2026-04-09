# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Transport
        module Exchanges
          # Thin alias that delegates exchange definition to Legion::LLM::Fleet::Exchange.
          # This class exists solely so Ollama::Transport topology introspection has a
          # local reference without importing legion-llm internals directly.
          class LlmRequest < Legion::LLM::Fleet::Exchange
          end
        end
      end
    end
  end
end

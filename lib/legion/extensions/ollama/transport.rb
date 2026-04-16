# frozen_string_literal: true

begin
  require 'legion/extensions/transport'
rescue LoadError
  nil
end

module Legion
  module Extensions
    module Ollama
      module Transport
        extend Legion::Extensions::Transport if Legion::Extensions.const_defined?(:Transport, false)

        # All queue-to-exchange bindings for fleet queues are established dynamically by
        # Actor::ModelWorker at subscription time via build_queue_class.
      end
    end
  end
end

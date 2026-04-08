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

        # All queue-to-exchange bindings are established dynamically by
        # Actor::ModelWorker#build_and_bind_queue at subscription time.
        # This file only needs to declare the exchange so topology/infra mode
        # can introspect the full routing graph.
        def self.additional_e_to_q
          []
        end
      end
    end
  end
end

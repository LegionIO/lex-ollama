# frozen_string_literal: true

require 'bundler/setup'
begin
  require 'legion/transport'
rescue LoadError
  module Legion
    module Transport
      def self.const_missing(name)
        const_set(name, Class.new)
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Stub Legion::Extensions constants not present without a full Legion runtime.
# Defined BEFORE loading lex-ollama so the conditional transport/actor requires
# fire and the fleet classes are fully defined during the test suite.
# ---------------------------------------------------------------------------
module Legion
  module Extensions
    module Core; end unless const_defined?(:Core, false)

    unless const_defined?(:Actors, false)
      module Actors
        class Subscription
          def initialize(**); end
          def runner_class    = raise(NotImplementedError)
          def runner_function = raise(NotImplementedError)
          def use_runner?     = true
        end
      end
    end
  end
end

require 'legion/extensions/ollama'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end

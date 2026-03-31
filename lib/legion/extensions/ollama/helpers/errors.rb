# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Helpers
        module Errors
          MAX_RETRIES = 3
          BASE_DELAY = 0.5
          MAX_DELAY = 16

          RETRYABLE_EXCEPTIONS = [
            Faraday::TimeoutError,
            Faraday::ConnectionFailed
          ].freeze

          module_function

          def retryable?(exception)
            RETRYABLE_EXCEPTIONS.any? { |klass| exception.is_a?(klass) }
          end

          def with_retry(max_retries: MAX_RETRIES)
            retries = 0
            begin
              yield
            rescue *RETRYABLE_EXCEPTIONS
              retries += 1
              raise if retries > max_retries

              delay = [BASE_DELAY * (2**(retries - 1)), MAX_DELAY].min
              sleep(delay)
              retry
            end
          end
        end
      end
    end
  end
end

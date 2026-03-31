# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Helpers
        module Usage
          EMPTY_USAGE = {
            input_tokens:         0,
            output_tokens:        0,
            total_duration:       0,
            load_duration:        0,
            prompt_eval_duration: 0,
            eval_duration:        0
          }.freeze

          module_function

          def from_response(body)
            return EMPTY_USAGE.dup unless body.is_a?(Hash)

            {
              input_tokens:         body['prompt_eval_count'] || 0,
              output_tokens:        body['eval_count'] || 0,
              total_duration:       body['total_duration'] || 0,
              load_duration:        body['load_duration'] || 0,
              prompt_eval_duration: body['prompt_eval_duration'] || 0,
              eval_duration:        body['eval_duration'] || 0
            }
          end
        end
      end
    end
  end
end

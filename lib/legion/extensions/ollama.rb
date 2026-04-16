# frozen_string_literal: true

require 'legion/extensions/ollama/version'
require 'legion/extensions/ollama/helpers/client'
require 'legion/extensions/ollama/helpers/errors'
require 'legion/extensions/ollama/helpers/usage'
require 'legion/extensions/ollama/runners/completions'
require 'legion/extensions/ollama/runners/chat'
require 'legion/extensions/ollama/runners/models'
require 'legion/extensions/ollama/runners/embeddings'
require 'legion/extensions/ollama/runners/blobs'
require 'legion/extensions/ollama/runners/s3_models'
require 'legion/extensions/ollama/runners/version'
require 'legion/extensions/ollama/runners/fleet'
require 'legion/extensions/ollama/client'

# Fleet transport and actor wiring — only loaded when Legion::Extensions::Core is present
# so the gem still works as a standalone HTTP client without any AMQP runtime.
if Legion::Extensions.const_defined?(:Core, false)
  require 'legion/extensions/ollama/transport/exchanges/llm_request'
  require 'legion/extensions/ollama/transport/messages/llm_response'
  require 'legion/extensions/ollama/transport'
  require 'legion/extensions/ollama/actors/model_worker'
  require 'legion/extensions/ollama/actors/model_sync'
end

module Legion
  module Extensions
    module Ollama
      extend Legion::Extensions::Core if Legion::Extensions.const_defined?(:Core, false)
    end
  end
end

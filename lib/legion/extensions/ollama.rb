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
require 'legion/extensions/ollama/runners/version'
require 'legion/extensions/ollama/client'

module Legion
  module Extensions
    module Ollama
      extend Legion::Extensions::Core if Legion::Extensions.const_defined? :Core
    end
  end
end

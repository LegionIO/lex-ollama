# frozen_string_literal: true

require_relative 'helpers/client'
require_relative 'runners/completions'
require_relative 'runners/chat'
require_relative 'runners/models'
require_relative 'runners/embeddings'
require_relative 'runners/blobs'
require_relative 'runners/version'

module Legion
  module Extensions
    module Ollama
      class Client
        include Helpers::Client
        include Runners::Completions
        include Runners::Chat
        include Runners::Models
        include Runners::Embeddings
        include Runners::Blobs
        include Runners::Version

        attr_reader :opts

        def initialize(host: Helpers::Client::DEFAULT_HOST, **)
          @opts = { host: host }.compact
        end

        def client(**override)
          super(**@opts, **override)
        end
      end
    end
  end
end

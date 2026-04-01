# frozen_string_literal: true

require 'legion/extensions/s3/client'

RSpec.describe Legion::Extensions::Ollama::Runners::S3Models do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:s3_client) { instance_double(Legion::Extensions::S3::Client) }

  before do
    allow(Legion::Extensions::S3::Client).to receive(:new).and_return(s3_client)
  end

  describe '#list_s3_models' do
    it 'lists models from S3 manifest keys' do
      allow(s3_client).to receive(:list_objects).with(
        bucket: 'legion',
        prefix: 'ollama/models/manifests/registry.ollama.ai/library/',
        max_keys: 1000
      ).and_return({
                     objects: [
                       { key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest', size: 512,
                         last_modified: '2026-04-01' },
                       { key: 'ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest', size: 256,
                         last_modified: '2026-04-01' }
                     ],
                     count: 2
                   })

      result = client_instance.list_s3_models(bucket: 'legion', prefix: 'ollama/models')
      expect(result[:models]).to eq([
                                      { name: 'llama3', tag: 'latest' },
                                      { name: 'nomic-embed-text', tag: 'latest' }
                                    ])
      expect(result[:status]).to eq(200)
    end

    it 'returns empty list when no models exist' do
      allow(s3_client).to receive(:list_objects).and_return({ objects: [], count: 0 })

      result = client_instance.list_s3_models(bucket: 'legion', prefix: 'ollama/models')
      expect(result[:models]).to eq([])
    end
  end
end

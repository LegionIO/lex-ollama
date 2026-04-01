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
        bucket:   'legion',
        prefix:   'ollama/models/manifests/registry.ollama.ai/library/',
        max_keys: 1000
      ).and_return({
                     objects: [
                       { key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest', size: 512,
                         last_modified: '2026-04-01' },
                       { key: 'ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest', size: 256,
                         last_modified: '2026-04-01' }
                     ],
                     count:   2
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

  describe '#import_from_s3' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:manifest_json) do
      JSON.dump({
                  'schemaVersion' => 2,
                  'config'        => { 'digest' => 'sha256:aaa111', 'size' => 100 },
                  'layers'        => [
                    { 'digest' => 'sha256:bbb222', 'size' => 4_000_000_000 },
                    { 'digest' => 'sha256:ccc333', 'size' => 512 }
                  ]
                })
    end

    after { FileUtils.remove_entry(tmp_dir) }

    it 'downloads manifest and streams blobs to local filesystem' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, key:, target:, **|
        File.binwrite(target, "blob_data_#{key}")
      end

      result = client_instance.import_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:result]).to eq(true)
      expect(result[:model]).to eq('llama3:latest')
      expect(result[:blobs_downloaded]).to eq(3)
      expect(result[:blobs_skipped]).to eq(0)
      expect(result[:status]).to eq(200)

      manifest_path = File.join(tmp_dir, 'manifests', 'registry.ollama.ai', 'library', 'llama3', 'latest')
      expect(File.exist?(manifest_path)).to be(true)
      expect(File.read(manifest_path)).to eq(manifest_json)

      expect(File.exist?(File.join(tmp_dir, 'blobs', 'sha256-aaa111'))).to be(true)
      expect(File.exist?(File.join(tmp_dir, 'blobs', 'sha256-bbb222'))).to be(true)
      expect(File.exist?(File.join(tmp_dir, 'blobs', 'sha256-ccc333'))).to be(true)
    end

    it 'skips blobs that already exist with matching size' do
      blob_dir = File.join(tmp_dir, 'blobs')
      FileUtils.mkdir_p(blob_dir)
      File.binwrite(File.join(blob_dir, 'sha256-bbb222'), 'b' * 15)

      manifest_with_small_layer = JSON.dump({
                                              'schemaVersion' => 2,
                                              'config'        => { 'digest' => 'sha256:aaa111', 'size' => 100 },
                                              'layers'        => [
                                                { 'digest' => 'sha256:bbb222', 'size' => 15 },
                                                { 'digest' => 'sha256:ccc333', 'size' => 512 }
                                              ]
                                            })

      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_with_small_layer, content_type: 'application/json',
                      content_length: manifest_with_small_layer.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, key:, target:, **|
        File.binwrite(target, "blob_data_#{key}")
      end

      result = client_instance.import_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:blobs_downloaded]).to eq(2)
      expect(result[:blobs_skipped]).to eq(1)
      expect(result[:status]).to eq(200)
    end

    it 'defaults tag to latest when model has no colon' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/mistral/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, target:, **|
        File.binwrite(target, 'data')
      end

      result = client_instance.import_from_s3(
        model: 'mistral', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:result]).to eq(true)
      manifest_path = File.join(tmp_dir, 'manifests', 'registry.ollama.ai', 'library', 'mistral', 'latest')
      expect(File.exist?(manifest_path)).to be(true)
    end
  end

  describe '#sync_from_s3' do
    let(:faraday_conn) { instance_double(Faraday::Connection) }
    let(:tmp_dir) { Dir.mktmpdir }
    let(:manifest_json) do
      JSON.dump({
                  'schemaVersion' => 2,
                  'config'        => { 'digest' => 'sha256:aaa111', 'size' => 100 },
                  'layers'        => [
                    { 'digest' => 'sha256:bbb222', 'size' => 4_000_000_000 },
                    { 'digest' => 'sha256:ccc333', 'size' => 512 }
                  ]
                })
    end

    before do
      allow(client_instance).to receive(:client).and_return(faraday_conn)
    end

    after { FileUtils.remove_entry(tmp_dir) }

    it 'pushes blobs through Ollama API and writes manifest' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, key:, target:, **|
        File.binwrite(target, "data_for_#{key}")
      end

      %w[sha256:aaa111 sha256:bbb222 sha256:ccc333].each do |digest|
        allow(faraday_conn).to receive(:head).with("/api/blobs/#{digest}")
                                             .and_return(instance_double(Faraday::Response, status: 404))

        allow(faraday_conn).to receive(:post).with("/api/blobs/#{digest}")
                                             .and_yield(instance_double(Faraday::Request, headers: {}).tap do |req|
                                                          allow(req).to receive(:body=)
                                                          allow(req).to receive(:headers).and_return({})
                                                        end).and_return(instance_double(Faraday::Response, status: 201))
      end

      result = client_instance.sync_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:result]).to be(true)
      expect(result[:model]).to eq('llama3:latest')
      expect(result[:blobs_pushed]).to eq(3)
      expect(result[:blobs_skipped]).to eq(0)
      expect(result[:status]).to eq(200)

      manifest_path = File.join(tmp_dir, 'manifests', 'registry.ollama.ai', 'library', 'llama3', 'latest')
      expect(File.exist?(manifest_path)).to be(true)
    end

    it 'skips blobs already present in Ollama' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, key:, target:, **|
        File.binwrite(target, "data_for_#{key}")
      end

      allow(faraday_conn).to receive(:head).with('/api/blobs/sha256:aaa111')
                                           .and_return(instance_double(Faraday::Response, status: 200))

      %w[sha256:bbb222 sha256:ccc333].each do |digest|
        allow(faraday_conn).to receive(:head).with("/api/blobs/#{digest}")
                                             .and_return(instance_double(Faraday::Response, status: 404))

        allow(faraday_conn).to receive(:post).with("/api/blobs/#{digest}")
                                             .and_yield(instance_double(Faraday::Request, headers: {}).tap do |req|
                                                          allow(req).to receive(:body=)
                                                          allow(req).to receive(:headers).and_return({})
                                                        end).and_return(instance_double(Faraday::Response, status: 201))
      end

      result = client_instance.sync_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:result]).to be(true)
      expect(result[:blobs_pushed]).to eq(2)
      expect(result[:blobs_skipped]).to eq(1)
    end

    it 'returns failure when blob push fails' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, target:, **|
        File.binwrite(target, 'data')
      end

      allow(faraday_conn).to receive(:head).and_return(instance_double(Faraday::Response, status: 404))

      # First push succeeds, rest fail
      call_count = 0
      allow(faraday_conn).to receive(:post).with(%r{/api/blobs/}) do |&block|
        call_count += 1
        req = instance_double(Faraday::Request, headers: {})
        allow(req).to receive(:body=)
        allow(req).to receive(:headers).and_return({})
        block&.call(req)
        if call_count <= 1
          instance_double(Faraday::Response, status: 201)
        else
          instance_double(Faraday::Response, status: 500)
        end
      end

      result = client_instance.sync_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:result]).to be(false)
      expect(result[:errors]).not_to be_empty
      expect(result[:status]).to eq(500)

      # Manifest should NOT be written on failure
      manifest_path = File.join(tmp_dir, 'manifests', 'registry.ollama.ai', 'library', 'llama3', 'latest')
      expect(File.exist?(manifest_path)).to be(false)
    end
  end

  describe '#import_default_models' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:manifest_json) do
      JSON.dump({
                  'schemaVersion' => 2,
                  'config'        => { 'digest' => 'sha256:aaa111', 'size' => 4 },
                  'layers'        => []
                })
    end

    after { FileUtils.remove_entry(tmp_dir) }

    it 'imports each model from the default_models list' do
      %w[llama3 nomic-embed-text].each do |name|
        allow(s3_client).to receive(:get_object)
          .with(bucket: 'legion', key: "ollama/models/manifests/registry.ollama.ai/library/#{name}/latest")
          .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                        content_length: manifest_json.bytesize })
      end

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, target:, **|
        File.binwrite(target, 'data')
      end

      result = client_instance.import_default_models(
        default_models: %w[llama3:latest nomic-embed-text:latest],
        bucket:         'legion',
        models_path:    tmp_dir
      )

      expect(result[:result].length).to eq(2)
      expect(result[:result]).to all(include(result: true))
      expect(result[:status]).to eq(200)
    end
  end
end

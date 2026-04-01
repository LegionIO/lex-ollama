# frozen_string_literal: true

require 'digest'
require 'legion/extensions/s3/client'

RSpec.describe Legion::Extensions::Ollama::Runners::S3Models do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:s3_client) { instance_double(Legion::Extensions::S3::Client) }

  # Real content and matching SHA256 digests for verification tests
  let(:blob_content) do
    { 'config' => 'config_data', 'layer1' => 'layer_one', 'layer2' => 'layer_two' }
  end
  let(:config_hex) { Digest::SHA256.hexdigest('config_data') }
  let(:layer1_hex) { Digest::SHA256.hexdigest('layer_one') }
  let(:layer2_hex) { Digest::SHA256.hexdigest('layer_two') }

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
                  'config'        => { 'digest' => "sha256:#{config_hex}", 'size' => 11 },
                  'layers'        => [
                    { 'digest' => "sha256:#{layer1_hex}", 'size' => 9 },
                    { 'digest' => "sha256:#{layer2_hex}", 'size' => 9 }
                  ]
                })
    end

    after { FileUtils.remove_entry(tmp_dir) }

    # Maps digest hex to the correct content for that blob
    def stub_s3_streaming_with_correct_content
      content_map = { config_hex => 'config_data', layer1_hex => 'layer_one', layer2_hex => 'layer_two' }
      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, key:, target:, **|
        hex = key.split('sha256-').last
        File.binwrite(target, content_map[hex] || "unknown_#{hex}")
      end
    end

    it 'downloads manifest and streams blobs to local filesystem' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      stub_s3_streaming_with_correct_content

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

      expect(File.exist?(File.join(tmp_dir, 'blobs', "sha256-#{config_hex}"))).to be(true)
      expect(File.exist?(File.join(tmp_dir, 'blobs', "sha256-#{layer1_hex}"))).to be(true)
      expect(File.exist?(File.join(tmp_dir, 'blobs', "sha256-#{layer2_hex}"))).to be(true)
    end

    it 'skips blobs that already exist with matching digest' do
      blob_dir = File.join(tmp_dir, 'blobs')
      FileUtils.mkdir_p(blob_dir)
      File.binwrite(File.join(blob_dir, "sha256-#{layer1_hex}"), 'layer_one')

      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      stub_s3_streaming_with_correct_content

      result = client_instance.import_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:blobs_downloaded]).to eq(2)
      expect(result[:blobs_skipped]).to eq(1)
      expect(result[:status]).to eq(200)
    end

    it 're-downloads blobs with wrong digest even if file exists' do
      blob_dir = File.join(tmp_dir, 'blobs')
      FileUtils.mkdir_p(blob_dir)
      File.binwrite(File.join(blob_dir, "sha256-#{layer1_hex}"), 'corrupted_content')

      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      stub_s3_streaming_with_correct_content

      result = client_instance.import_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:blobs_downloaded]).to eq(3)
      expect(result[:blobs_skipped]).to eq(0)
      expect(File.read(File.join(blob_dir, "sha256-#{layer1_hex}"))).to eq('layer_one')
    end

    it 'raises DigestMismatchError when downloaded blob has wrong digest' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      # Write wrong content for one blob
      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, target:, **|
        File.binwrite(target, 'wrong_content_for_every_blob')
      end

      expect do
        client_instance.import_from_s3(
          model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
        )
      end.to raise_error(Legion::Extensions::Ollama::Runners::S3Models::DigestMismatchError)
    end

    it 'cleans up temp file on digest mismatch' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, target:, **|
        File.binwrite(target, 'bad_data')
      end

      begin
        client_instance.import_from_s3(
          model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
        )
      rescue Legion::Extensions::Ollama::Runners::S3Models::DigestMismatchError
        # expected
      end

      # No .tmp files should remain
      tmp_files = Dir.glob(File.join(tmp_dir, 'blobs', '*.tmp'))
      expect(tmp_files).to be_empty
    end

    it 'defaults tag to latest when model has no colon' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/mistral/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      stub_s3_streaming_with_correct_content

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
                  'config'        => { 'digest' => "sha256:#{config_hex}", 'size' => 11 },
                  'layers'        => [
                    { 'digest' => "sha256:#{layer1_hex}", 'size' => 9 },
                    { 'digest' => "sha256:#{layer2_hex}", 'size' => 9 }
                  ]
                })
    end

    before do
      allow(client_instance).to receive(:client).and_return(faraday_conn)
    end

    after { FileUtils.remove_entry(tmp_dir) }

    def stub_s3_streaming_with_correct_content
      content_map = { config_hex => 'config_data', layer1_hex => 'layer_one', layer2_hex => 'layer_two' }
      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, key:, target:, **|
        hex = key.split('sha256-').last
        File.binwrite(target, content_map[hex] || "unknown_#{hex}")
      end
    end

    it 'pushes blobs through Ollama API and writes manifest' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      stub_s3_streaming_with_correct_content

      %W[sha256:#{config_hex} sha256:#{layer1_hex} sha256:#{layer2_hex}].each do |digest|
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

      stub_s3_streaming_with_correct_content

      allow(faraday_conn).to receive(:head).with("/api/blobs/sha256:#{config_hex}")
                                           .and_return(instance_double(Faraday::Response, status: 200))

      %W[sha256:#{layer1_hex} sha256:#{layer2_hex}].each do |digest|
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

      stub_s3_streaming_with_correct_content

      allow(faraday_conn).to receive(:head).and_return(instance_double(Faraday::Response, status: 404))

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

      manifest_path = File.join(tmp_dir, 'manifests', 'registry.ollama.ai', 'library', 'llama3', 'latest')
      expect(File.exist?(manifest_path)).to be(false)
    end

    it 'returns failure when downloaded blob has wrong digest' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ key: '', body: manifest_json, content_type: 'application/json',
                      content_length: manifest_json.bytesize })

      allow(client_instance).to receive(:stream_s3_to_file) do |_s3, target:, **|
        File.binwrite(target, 'corrupted_from_s3')
      end

      allow(faraday_conn).to receive(:head).and_return(instance_double(Faraday::Response, status: 404))

      result = client_instance.sync_from_s3(
        model: 'llama3:latest', bucket: 'legion', prefix: 'ollama/models', models_path: tmp_dir
      )

      expect(result[:result]).to be(false)
      expect(result[:errors].first[:error]).to eq('digest mismatch')
      expect(result[:status]).to eq(500)
    end
  end

  describe '#import_default_models' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:config_content) { 'default_config' }
    let(:default_config_hex) { Digest::SHA256.hexdigest(config_content) }
    let(:manifest_json) do
      JSON.dump({
                  'schemaVersion' => 2,
                  'config'        => { 'digest' => "sha256:#{default_config_hex}", 'size' => config_content.bytesize },
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
        File.binwrite(target, config_content)
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

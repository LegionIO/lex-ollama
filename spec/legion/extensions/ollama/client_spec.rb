# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Client do
  subject(:client) { described_class.new }

  describe '#initialize' do
    it 'creates a client with default host' do
      expect(client.opts).to eq({ host: 'http://localhost:11434' })
    end

    it 'accepts a custom host' do
      custom = described_class.new(host: 'http://remote:11434')
      expect(custom.opts).to eq({ host: 'http://remote:11434' })
    end
  end

  describe '#client' do
    it 'returns a Faraday connection' do
      expect(client.client).to be_a(Faraday::Connection)
    end

    it 'uses the configured host' do
      conn = client.client
      expect(conn.url_prefix.to_s).to eq('http://localhost:11434/')
    end

    it 'allows host override' do
      conn = client.client(host: 'http://other:11434')
      expect(conn.url_prefix.to_s).to eq('http://other:11434/')
    end
  end

  describe '#streaming_client' do
    it 'returns a Faraday connection' do
      expect(client.streaming_client).to be_a(Faraday::Connection)
    end

    it 'uses the configured host' do
      conn = client.streaming_client
      expect(conn.url_prefix.to_s).to eq('http://localhost:11434/')
    end

    it 'allows host override' do
      conn = client.streaming_client(host: 'http://other:11434')
      expect(conn.url_prefix.to_s).to eq('http://other:11434/')
    end
  end

  describe 'runner inclusion' do
    it { is_expected.to respond_to(:generate) }
    it { is_expected.to respond_to(:generate_stream) }
    it { is_expected.to respond_to(:chat) }
    it { is_expected.to respond_to(:chat_stream) }
    it { is_expected.to respond_to(:create_model) }
    it { is_expected.to respond_to(:list_models) }
    it { is_expected.to respond_to(:show_model) }
    it { is_expected.to respond_to(:copy_model) }
    it { is_expected.to respond_to(:delete_model) }
    it { is_expected.to respond_to(:pull_model) }
    it { is_expected.to respond_to(:push_model) }
    it { is_expected.to respond_to(:list_running) }
    it { is_expected.to respond_to(:embed) }
    it { is_expected.to respond_to(:check_blob) }
    it { is_expected.to respond_to(:push_blob) }
    it { is_expected.to respond_to(:server_version) }
  end
end

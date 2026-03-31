# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Helpers::Client do
  let(:test_class) do
    Class.new do
      include Legion::Extensions::Ollama::Helpers::Client
    end
  end
  let(:instance) { test_class.new }

  describe '#client' do
    it 'returns a Faraday connection' do
      expect(instance.client).to be_a(Faraday::Connection)
    end

    it 'defaults to localhost:11434' do
      conn = instance.client
      expect(conn.url_prefix.to_s).to eq('http://localhost:11434/')
    end

    it 'accepts a custom host' do
      conn = instance.client(host: 'http://remote-server:11434')
      expect(conn.url_prefix.to_s).to eq('http://remote-server:11434/')
    end

    it 'sets a 300 second timeout' do
      conn = instance.client
      expect(conn.options.timeout).to eq(300)
    end

    it 'sets a 10 second open timeout' do
      conn = instance.client
      expect(conn.options.open_timeout).to eq(10)
    end
  end

  describe 'DEFAULT_HOST' do
    it 'is http://localhost:11434' do
      expect(Legion::Extensions::Ollama::Helpers::Client::DEFAULT_HOST).to eq('http://localhost:11434')
    end
  end
end

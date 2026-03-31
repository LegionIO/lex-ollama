# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Embeddings do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
  end

  describe '#embed' do
    it 'generates embeddings for a single input' do
      body = { 'model' => 'all-minilm', 'embeddings' => [[0.01, -0.002, 0.05]] }
      response = instance_double(Faraday::Response, body: body, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/embed', { model: 'all-minilm', input: 'Why is the sky blue?' }).and_return(response)

      result = client_instance.embed(model: 'all-minilm', input: 'Why is the sky blue?')
      expect(result[:result]['embeddings']).to be_an(Array)
      expect(result[:status]).to eq(200)
    end

    it 'generates embeddings for multiple inputs' do
      body = { 'model' => 'all-minilm', 'embeddings' => [[0.01], [-0.01]] }
      response = instance_double(Faraday::Response, body: body, status: 200)
      inputs = ['Why is the sky blue?', 'Why is the grass green?']
      allow(faraday_conn).to receive(:post).with('/api/embed', { model: 'all-minilm', input: inputs }).and_return(response)

      result = client_instance.embed(model: 'all-minilm', input: inputs)
      expect(result[:result]['embeddings'].length).to eq(2)
    end

    it 'supports optional dimensions parameter' do
      body = { 'model' => 'all-minilm', 'embeddings' => [[0.01, -0.002]] }
      response = instance_double(Faraday::Response, body: body, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/embed', { model: 'all-minilm', input: 'test', dimensions: 512 }).and_return(response)

      result = client_instance.embed(model: 'all-minilm', input: 'test', dimensions: 512)
      expect(result[:status]).to eq(200)
    end
  end
end

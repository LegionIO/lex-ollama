# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Completions do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }
  let(:response) { instance_double(Faraday::Response, body: response_body, status: 200) }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
  end

  describe '#generate' do
    let(:response_body) do
      {
        'model'    => 'llama3.2',
        'response' => 'The sky is blue because of Rayleigh scattering.',
        'done'     => true
      }
    end

    it 'sends a generate request' do
      allow(faraday_conn).to receive(:post).with('/api/generate', { model: 'llama3.2', prompt: 'Why is the sky blue?', stream: false }).and_return(response)

      result = client_instance.generate(model: 'llama3.2', prompt: 'Why is the sky blue?')
      expect(result[:result]).to eq(response_body)
      expect(result[:status]).to eq(200)
    end

    it 'includes optional parameters when provided' do
      allow(faraday_conn).to receive(:post).with('/api/generate', {
                                                   model: 'llama3.2', prompt: 'Hello', stream: false,
                                                   format: 'json', system: 'You are helpful.'
                                                 }).and_return(response)

      result = client_instance.generate(model: 'llama3.2', prompt: 'Hello', format: 'json', system: 'You are helpful.')
      expect(result[:status]).to eq(200)
    end

    it 'sends without prompt to load model' do
      allow(faraday_conn).to receive(:post).with('/api/generate', { model: 'llama3.2', stream: false }).and_return(response)

      result = client_instance.generate(model: 'llama3.2')
      expect(result[:status]).to eq(200)
    end

    it 'supports images for multimodal models' do
      allow(faraday_conn).to receive(:post).with('/api/generate', {
                                                   model: 'llava', prompt: 'What is this?',
                                                   images: ['base64data'], stream: false
                                                 }).and_return(response)

      result = client_instance.generate(model: 'llava', prompt: 'What is this?', images: ['base64data'])
      expect(result[:status]).to eq(200)
    end
  end
end

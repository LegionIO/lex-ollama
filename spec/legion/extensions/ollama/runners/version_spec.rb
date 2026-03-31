# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Version do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
  end

  describe '#server_version' do
    it 'returns the ollama server version' do
      body = { 'version' => '0.5.1' }
      response = instance_double(Faraday::Response, body: body, status: 200)
      allow(faraday_conn).to receive(:get).with('/api/version').and_return(response)

      result = client_instance.server_version
      expect(result[:result]['version']).to eq('0.5.1')
      expect(result[:status]).to eq(200)
    end
  end
end

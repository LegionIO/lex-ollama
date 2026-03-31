# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Blobs do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }
  let(:digest) { 'sha256:29fdb92e57cf0827ded04ae6461b5931d01fa595843f55d36f5b275a52087dd2' }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
  end

  describe '#check_blob' do
    it 'returns true when blob exists' do
      response = instance_double(Faraday::Response, status: 200)
      allow(faraday_conn).to receive(:head).with("/api/blobs/#{digest}").and_return(response)

      result = client_instance.check_blob(digest: digest)
      expect(result[:result]).to be(true)
      expect(result[:status]).to eq(200)
    end

    it 'returns false when blob does not exist' do
      response = instance_double(Faraday::Response, status: 404)
      allow(faraday_conn).to receive(:head).with("/api/blobs/#{digest}").and_return(response)

      result = client_instance.check_blob(digest: digest)
      expect(result[:result]).to be(false)
      expect(result[:status]).to eq(404)
    end
  end

  describe '#push_blob' do
    it 'uploads a blob successfully' do
      response = instance_double(Faraday::Response, status: 201)
      allow(faraday_conn).to receive(:post).and_yield(instance_double(Faraday::Request, headers: {}).tap do |req|
        allow(req).to receive(:body=)
        allow(req).to receive(:headers).and_return({})
      end).and_return(response)

      result = client_instance.push_blob(digest: digest, body: 'binary data')
      expect(result[:result]).to be(true)
      expect(result[:status]).to eq(201)
    end

    it 'returns false on bad request' do
      response = instance_double(Faraday::Response, status: 400)
      allow(faraday_conn).to receive(:post).and_yield(instance_double(Faraday::Request, headers: {}).tap do |req|
        allow(req).to receive(:body=)
        allow(req).to receive(:headers).and_return({})
      end).and_return(response)

      result = client_instance.push_blob(digest: digest, body: 'bad data')
      expect(result[:result]).to be(false)
      expect(result[:status]).to eq(400)
    end
  end
end

# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Models do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
  end

  describe '#create_model' do
    it 'creates a model from an existing model' do
      response = instance_double(Faraday::Response, body: { 'status' => 'success' }, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/create', {
                                                   model: 'mario', from: 'llama3.2',
                                                   system: 'You are Mario.', stream: false
                                                 }).and_return(response)

      result = client_instance.create_model(model: 'mario', from: 'llama3.2', system: 'You are Mario.')
      expect(result[:status]).to eq(200)
    end
  end

  describe '#list_models' do
    it 'returns available models' do
      body = { 'models' => [{ 'name' => 'llama3.2:latest' }] }
      response = instance_double(Faraday::Response, body: body, status: 200)
      allow(faraday_conn).to receive(:get).with('/api/tags').and_return(response)

      result = client_instance.list_models
      expect(result[:result]['models']).to be_an(Array)
      expect(result[:status]).to eq(200)
    end
  end

  describe '#show_model' do
    it 'returns model information' do
      body = { 'details' => { 'family' => 'llama' } }
      response = instance_double(Faraday::Response, body: body, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/show', { model: 'llava' }).and_return(response)

      result = client_instance.show_model(model: 'llava')
      expect(result[:result]['details']).to include('family' => 'llama')
    end
  end

  describe '#copy_model' do
    it 'copies a model' do
      response = instance_double(Faraday::Response, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/copy', { source: 'llama3.2', destination: 'llama3-backup' }).and_return(response)

      result = client_instance.copy_model(source: 'llama3.2', destination: 'llama3-backup')
      expect(result[:result]).to be(true)
    end
  end

  describe '#delete_model' do
    it 'deletes a model' do
      response = instance_double(Faraday::Response, status: 200)
      allow(faraday_conn).to receive(:delete).and_yield(instance_double(Faraday::Request, body: nil).tap do |req|
        allow(req).to receive(:body=)
      end).and_return(response)

      result = client_instance.delete_model(model: 'llama3:13b')
      expect(result[:result]).to be(true)
    end
  end

  describe '#pull_model' do
    it 'pulls a model' do
      response = instance_double(Faraday::Response, body: { 'status' => 'success' }, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/pull', { model: 'llama3.2', stream: false }).and_return(response)

      result = client_instance.pull_model(model: 'llama3.2')
      expect(result[:result]['status']).to eq('success')
    end
  end

  describe '#push_model' do
    it 'pushes a model' do
      response = instance_double(Faraday::Response, body: { 'status' => 'success' }, status: 200)
      allow(faraday_conn).to receive(:post).with('/api/push', { model: 'user/model:latest', stream: false }).and_return(response)

      result = client_instance.push_model(model: 'user/model:latest')
      expect(result[:result]['status']).to eq('success')
    end
  end

  describe '#list_running' do
    it 'lists running models' do
      body = { 'models' => [{ 'name' => 'mistral:latest' }] }
      response = instance_double(Faraday::Response, body: body, status: 200)
      allow(faraday_conn).to receive(:get).with('/api/ps').and_return(response)

      result = client_instance.list_running
      expect(result[:result]['models']).to be_an(Array)
    end
  end
end

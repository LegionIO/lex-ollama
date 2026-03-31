# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Chat do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }
  let(:response) { instance_double(Faraday::Response, body: response_body, status: 200) }
  let(:messages) { [{ 'role' => 'user', 'content' => 'Hello' }] }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
  end

  describe '#chat' do
    let(:response_body) do
      {
        'model'   => 'llama3.2',
        'message' => { 'role' => 'assistant', 'content' => 'Hi there!' },
        'done'    => true
      }
    end

    it 'sends a chat request' do
      allow(faraday_conn).to receive(:post).with('/api/chat', { model: 'llama3.2', messages: messages, stream: false }).and_return(response)

      result = client_instance.chat(model: 'llama3.2', messages: messages)
      expect(result[:result]).to eq(response_body)
      expect(result[:status]).to eq(200)
    end

    it 'includes tools when provided' do
      tools = [{ 'type' => 'function', 'function' => { 'name' => 'get_weather' } }]
      allow(faraday_conn).to receive(:post).with('/api/chat', {
                                                   model: 'llama3.2', messages: messages,
                                                   tools: tools, stream: false
                                                 }).and_return(response)

      result = client_instance.chat(model: 'llama3.2', messages: messages, tools: tools)
      expect(result[:status]).to eq(200)
    end

    it 'supports format parameter for structured output' do
      schema = { 'type' => 'object', 'properties' => { 'age' => { 'type' => 'integer' } } }
      allow(faraday_conn).to receive(:post).with('/api/chat', {
                                                   model: 'llama3.2', messages: messages,
                                                   format: schema, stream: false
                                                 }).and_return(response)

      result = client_instance.chat(model: 'llama3.2', messages: messages, format: schema)
      expect(result[:status]).to eq(200)
    end

    it 'supports think parameter for thinking models' do
      allow(faraday_conn).to receive(:post).with('/api/chat', {
                                                   model: 'deepseek-r1', messages: messages,
                                                   think: true, stream: false
                                                 }).and_return(response)

      result = client_instance.chat(model: 'deepseek-r1', messages: messages, think: true)
      expect(result[:status]).to eq(200)
    end
  end
end

# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Chat do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }
  let(:streaming_conn) { instance_double(Faraday::Connection) }
  let(:response) { instance_double(Faraday::Response, body: response_body, status: 200) }
  let(:messages) { [{ 'role' => 'user', 'content' => 'Hello' }] }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
    allow(client_instance).to receive(:streaming_client).and_return(streaming_conn)
  end

  describe '#chat' do
    let(:response_body) do
      {
        'model'                => 'llama3.2',
        'message'              => { 'role' => 'assistant', 'content' => 'Hi there!' },
        'done'                 => true,
        'prompt_eval_count'    => 10,
        'eval_count'           => 5,
        'total_duration'       => 5_000_000,
        'load_duration'        => 1_000_000,
        'prompt_eval_duration' => 2_000_000,
        'eval_duration'        => 2_000_000
      }
    end

    it 'sends a chat request' do
      allow(faraday_conn).to receive(:post).with('/api/chat', { model: 'llama3.2', messages: messages, stream: false }).and_return(response)

      result = client_instance.chat(model: 'llama3.2', messages: messages)
      expect(result[:result]).to eq(response_body)
      expect(result[:status]).to eq(200)
    end

    it 'returns usage data' do
      allow(faraday_conn).to receive(:post).and_return(response)

      result = client_instance.chat(model: 'llama3.2', messages: messages)
      expect(result[:usage][:input_tokens]).to eq(10)
      expect(result[:usage][:output_tokens]).to eq(5)
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

    it 'retries on connection failure' do
      attempts = 0
      allow(faraday_conn).to receive(:post) do
        attempts += 1
        raise Faraday::ConnectionFailed, 'refused' if attempts < 2

        response
      end

      result = client_instance.chat(model: 'llama3.2', messages: messages)
      expect(result[:status]).to eq(200)
      expect(attempts).to eq(2)
    end
  end

  describe '#chat_stream' do
    let(:chunks) do
      [
        "{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"Hi\"},\"done\":false}\n",
        "{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\" there\"},\"done\":false}\n",
        '{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,' \
        '"prompt_eval_count":10,"eval_count":2,"total_duration":3000,' \
        "\"load_duration\":500,\"prompt_eval_duration\":1000,\"eval_duration\":1500}\n"
      ]
    end

    before do
      allow(streaming_conn).to receive(:post) do |_path, _body, &request_block|
        req = double('request', options: double('options'))
        on_data_proc = nil
        allow(req.options).to receive(:on_data=) { |proc| on_data_proc = proc }
        request_block&.call(req)
        chunks.each { |chunk| on_data_proc&.call(chunk, chunk.length) }
        double('response')
      end
    end

    it 'accumulates streamed text' do
      result = client_instance.chat_stream(model: 'llama3.2', messages: messages)
      expect(result[:result]).to eq('Hi there')
    end

    it 'returns usage from final response' do
      result = client_instance.chat_stream(model: 'llama3.2', messages: messages)
      expect(result[:usage][:input_tokens]).to eq(10)
      expect(result[:usage][:output_tokens]).to eq(2)
    end

    it 'yields delta events to block' do
      events = []
      client_instance.chat_stream(model: 'llama3.2', messages: messages) { |e| events << e }
      deltas = events.select { |e| e[:type] == :delta }
      expect(deltas.map { |e| e[:text] }).to eq(['Hi', ' there'])
    end

    it 'yields done event at end' do
      events = []
      client_instance.chat_stream(model: 'llama3.2', messages: messages) { |e| events << e }
      done = events.find { |e| e[:type] == :done }
      expect(done[:data]['done']).to be(true)
    end

    it 'returns status 200' do
      result = client_instance.chat_stream(model: 'llama3.2', messages: messages)
      expect(result[:status]).to eq(200)
    end
  end
end

# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Completions do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:faraday_conn) { instance_double(Faraday::Connection) }
  let(:streaming_conn) { instance_double(Faraday::Connection) }
  let(:response) { instance_double(Faraday::Response, body: response_body, status: 200) }

  before do
    allow(client_instance).to receive(:client).and_return(faraday_conn)
    allow(client_instance).to receive(:streaming_client).and_return(streaming_conn)
  end

  describe '#generate' do
    let(:response_body) do
      {
        'model'                => 'llama3.2',
        'response'             => 'The sky is blue because of Rayleigh scattering.',
        'done'                 => true,
        'prompt_eval_count'    => 26,
        'eval_count'           => 259,
        'total_duration'       => 10_706_818_083,
        'load_duration'        => 6_338_219_291,
        'prompt_eval_duration' => 130_079_000,
        'eval_duration'        => 4_232_710_000
      }
    end

    it 'sends a generate request' do
      allow(faraday_conn).to receive(:post).with('/api/generate', { model: 'llama3.2', prompt: 'Why is the sky blue?', stream: false }).and_return(response)

      result = client_instance.generate(model: 'llama3.2', prompt: 'Why is the sky blue?')
      expect(result[:result]).to eq(response_body)
      expect(result[:status]).to eq(200)
    end

    it 'returns usage data' do
      allow(faraday_conn).to receive(:post).and_return(response)

      result = client_instance.generate(model: 'llama3.2', prompt: 'test')
      expect(result[:usage][:input_tokens]).to eq(26)
      expect(result[:usage][:output_tokens]).to eq(259)
      expect(result[:usage][:total_duration]).to eq(10_706_818_083)
    end

    it 'includes optional parameters when provided' do
      allow(faraday_conn).to receive(:post).with('/api/generate', {
                                                   model: 'llama3.2', prompt: 'Hello', stream: false,
                                                   format: 'json', system: 'You are helpful.'
                                                 }).and_return(response)

      result = client_instance.generate(model: 'llama3.2', prompt: 'Hello', format: 'json', system: 'You are helpful.')
      expect(result[:status]).to eq(200)
    end

    it 'retries on timeout' do
      attempts = 0
      allow(faraday_conn).to receive(:post) do
        attempts += 1
        raise Faraday::TimeoutError if attempts < 2

        response
      end

      result = client_instance.generate(model: 'llama3.2', prompt: 'test')
      expect(result[:status]).to eq(200)
      expect(attempts).to eq(2)
    end
  end

  describe '#generate_stream' do
    let(:chunks) do
      [
        "{\"model\":\"llama3.2\",\"response\":\"The\",\"done\":false}\n",
        "{\"model\":\"llama3.2\",\"response\":\" sky\",\"done\":false}\n",
        '{"model":"llama3.2","response":"","done":true,' \
        '"prompt_eval_count":26,"eval_count":2,"total_duration":1000,' \
        "\"load_duration\":200,\"prompt_eval_duration\":300,\"eval_duration\":500}\n"
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
      result = client_instance.generate_stream(model: 'llama3.2', prompt: 'Why is the sky blue?')
      expect(result[:result]).to eq('The sky')
    end

    it 'returns usage from final response' do
      result = client_instance.generate_stream(model: 'llama3.2', prompt: 'test')
      expect(result[:usage][:input_tokens]).to eq(26)
      expect(result[:usage][:output_tokens]).to eq(2)
    end

    it 'yields delta events to block' do
      events = []
      client_instance.generate_stream(model: 'llama3.2', prompt: 'test') { |e| events << e }
      deltas = events.select { |e| e[:type] == :delta }
      expect(deltas.map { |e| e[:text] }).to eq(['The', ' sky'])
    end

    it 'yields done event at end' do
      events = []
      client_instance.generate_stream(model: 'llama3.2', prompt: 'test') { |e| events << e }
      done = events.find { |e| e[:type] == :done }
      expect(done[:data]['done']).to be(true)
    end

    it 'returns status 200' do
      result = client_instance.generate_stream(model: 'llama3.2', prompt: 'test')
      expect(result[:status]).to eq(200)
    end
  end
end

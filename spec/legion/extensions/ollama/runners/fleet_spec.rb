# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Runners::Fleet do
  subject(:fleet) { described_class }

  let(:client_instance) { instance_double(Legion::Extensions::Ollama::Client) }
  let(:embed_result)    { { result: { 'embeddings' => [[0.1, 0.2]] }, status: 200 } }
  let(:chat_result)     { { result: { 'message' => { 'content' => 'hello' } }, usage: {}, status: 200 } }
  let(:generate_result) { { result: { 'response' => 'text' }, usage: {}, status: 200 } }

  before do
    allow(Legion::Extensions::Ollama::Client).to receive(:new).and_return(client_instance)
    allow(client_instance).to receive(:embed).and_return(embed_result)
    allow(client_instance).to receive(:chat).and_return(chat_result)
    allow(client_instance).to receive(:generate).and_return(generate_result)

    stub_const('Legion::Transport', double('Legion::Transport'))
    allow(described_class).to receive(:publish_reply)
    allow(described_class).to receive(:publish_error)
  end

  describe '.handle_request' do
    context 'when request_type is embed' do
      it 'calls embed on the client' do
        fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                             input: 'hello world')
        expect(client_instance).to have_received(:embed).with(
          model: 'nomic-embed-text', input: 'hello world'
        )
      end

      it 'returns the embed result' do
        result = fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                                      input: 'hello world')
        expect(result[:status]).to eq(200)
        expect(result[:result]['embeddings']).to be_an(Array)
      end

      it 'uses :text as fallback when :input is absent' do
        fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                             text: 'hello world')
        expect(client_instance).to have_received(:embed).with(
          model: 'nomic-embed-text', input: 'hello world'
        )
      end
    end

    context 'when request_type is chat' do
      let(:messages) { [{ role: 'user', content: 'Hi' }] }

      it 'calls chat on the client' do
        fleet.handle_request(model: 'llama3.2', request_type: 'chat', messages: messages)
        expect(client_instance).to have_received(:chat).with(
          model: 'llama3.2', messages: messages
        )
      end

      it 'returns the chat result' do
        result = fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                                      messages: messages)
        expect(result[:status]).to eq(200)
      end
    end

    context 'when request_type is generate' do
      it 'calls generate on the client' do
        fleet.handle_request(model: 'llama3.2', request_type: 'generate',
                             prompt: 'Tell me a joke')
        expect(client_instance).to have_received(:generate).with(
          model: 'llama3.2', prompt: 'Tell me a joke'
        )
      end

      it 'returns the generate result' do
        result = fleet.handle_request(model: 'llama3.2', request_type: 'generate',
                                      prompt: 'Tell me a joke')
        expect(result[:status]).to eq(200)
      end
    end

    context 'when request_type is unknown' do
      it 'falls through to chat' do
        fleet.handle_request(model: 'llama3.2', request_type: 'unknown',
                             messages: [])
        expect(client_instance).to have_received(:chat)
      end
    end

    context 'when reply_to is provided' do
      it 'calls publish_reply with keyword arguments' do
        fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                             input: 'hi', reply_to: 'agent.caller', correlation_id: 'cid-1')
        expect(described_class).to have_received(:publish_reply).with(
          hash_including(reply_to: 'agent.caller', correlation_id: 'cid-1', model: 'nomic-embed-text')
        )
      end
    end

    context 'when reply_to is nil' do
      it 'does not call publish_reply' do
        fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed', input: 'hi')
        expect(described_class).not_to have_received(:publish_reply)
      end
    end

    context 'when the Ollama client raises an error' do
      before do
        allow(client_instance).to receive(:embed).and_raise(StandardError, 'connection refused')
      end

      it 'returns a 500 error result' do
        result = fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                                      input: 'hi')
        expect(result[:status]).to eq(500)
        expect(result[:error]).to eq('connection refused')
        expect(result[:result]).to be_nil
      end

      it 'does not raise' do
        expect do
          fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed', input: 'hi')
        end.not_to raise_error
      end
    end
  end

  describe 'message_context propagation' do
    it 'passes message_context to publish_reply' do
      ctx = { conversation_id: 'conv_123', request_id: 'req_abc' }
      fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                           input: 'hi', reply_to: 'q', correlation_id: 'cid',
                           message_context: ctx)
      expect(described_class).to have_received(:publish_reply)
        .with(hash_including(message_context: ctx))
    end

    it 'defaults message_context to empty hash when absent' do
      fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                           input: 'hi', reply_to: 'q', correlation_id: 'cid')
      expect(described_class).to have_received(:publish_reply)
        .with(hash_including(message_context: {}))
    end
  end

  describe 'stream rejection' do
    it 'returns 422 when stream: true' do
      result = fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                                    messages: [], reply_to: 'q', stream: true)
      expect(result[:status]).to eq(422)
      expect(result[:error]).to eq('unsupported_streaming')
    end

    it 'publishes an error with unsupported_streaming code' do
      fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                           messages: [], reply_to: 'q', stream: true)
      expect(described_class).to have_received(:publish_error)
        .with(hash_including(error: hash_including(code: 'unsupported_streaming')))
    end

    it 'does not call dispatch when stream: true' do
      fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                           messages: [], reply_to: 'q', stream: true)
      expect(client_instance).not_to have_received(:chat)
    end

    it 'passes message_context to publish_error' do
      ctx = { conversation_id: 'conv_123' }
      fleet.handle_request(model: 'llama3.2', request_type: 'chat',
                           messages: [], reply_to: 'q', stream: true,
                           message_context: ctx)
      expect(described_class).to have_received(:publish_error)
        .with(hash_including(message_context: ctx))
    end
  end

  describe '.build_response_body' do
    let(:now) { Time.now.utc }

    it 'includes routing block with provider, model, tier, strategy, latency_ms' do
      body = fleet.send(:build_response_body,
                        request_type: 'embed', body: { 'embeddings' => [[0.1]] },
                        usage: { input_tokens: 5, output_tokens: 0 },
                        status: 200, model: 'nomic-embed-text',
                        latency_ms: 42, received_at: now, returned_at: now)
      expect(body[:routing][:provider]).to eq('ollama')
      expect(body[:routing][:model]).to eq('nomic-embed-text')
      expect(body[:routing][:tier]).to eq('fleet')
      expect(body[:routing][:strategy]).to eq('fleet_dispatch')
      expect(body[:routing][:latency_ms]).to eq(42)
    end

    it 'includes tokens block with input, output, total' do
      body = fleet.send(:build_response_body,
                        request_type: 'embed', body: {},
                        usage: { input_tokens: 5, output_tokens: 3 },
                        status: 200, model: 'nomic-embed-text',
                        latency_ms: 10, received_at: now, returned_at: now)
      expect(body[:tokens]).to eq(input: 5, output: 3, total: 8)
    end

    it 'includes timestamps in ISO 8601 format' do
      body = fleet.send(:build_response_body,
                        request_type: 'embed', body: {},
                        usage: {}, status: 200, model: 'nomic-embed-text',
                        latency_ms: 10, received_at: now, returned_at: now)
      expect(body[:timestamps][:received]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it 'includes embeddings key for embed request_type' do
      body = fleet.send(:build_response_body,
                        request_type: 'embed', body: { 'embeddings' => [[0.1]] },
                        usage: {}, status: 200, model: 'nomic-embed-text',
                        latency_ms: 10, received_at: now, returned_at: now)
      expect(body[:embeddings]).to eq([[0.1]])
    end

    it 'includes message key for chat request_type' do
      body = fleet.send(:build_response_body,
                        request_type: 'chat',
                        body: { 'message' => { 'content' => 'hello' } },
                        usage: {}, status: 200, model: 'llama3.2',
                        latency_ms: 10, received_at: now, returned_at: now)
      expect(body[:message][:content]).to eq('hello')
      expect(body[:message][:role]).to eq('assistant')
    end

    it 'includes message key for generate request_type' do
      body = fleet.send(:build_response_body,
                        request_type: 'generate',
                        body: { 'response' => 'generated text' },
                        usage: {}, status: 200, model: 'llama3.2',
                        latency_ms: 10, received_at: now, returned_at: now)
      expect(body[:message][:content]).to eq('generated text')
      expect(body[:message][:role]).to eq('assistant')
    end

    it 'includes audit block' do
      body = fleet.send(:build_response_body,
                        request_type: 'chat', body: {},
                        usage: {}, status: 200, model: 'llama3.2',
                        latency_ms: 42, received_at: now, returned_at: now)
      expect(body[:audit]['fleet:execute'][:outcome]).to eq('success')
      expect(body[:audit]['fleet:execute'][:duration_ms]).to eq(42)
    end
  end

  describe '.publish_reply' do
    it 'swallows errors and does not raise' do
      allow(described_class).to receive(:publish_reply).and_call_original
      allow(Legion::Extensions::Ollama::Transport::Messages::LlmResponse)
        .to receive(:new).and_raise(StandardError, 'boom')

      expect do
        fleet.send(:publish_reply,
                   reply_to: 'q', correlation_id: 'cid', message_context: {},
                   model: 'x', request_type: 'chat',
                   result: { result: {}, status: 200 },
                   received_at: Time.now.utc, returned_at: Time.now.utc)
      end.not_to raise_error
    end
  end

  describe '.publish_error' do
    it 'swallows errors and does not raise' do
      allow(described_class).to receive(:publish_error).and_call_original
      allow(Legion::LLM::Fleet::Error).to receive(:new).and_raise(StandardError, 'boom')

      expect do
        fleet.send(:publish_error,
                   reply_to: 'q', correlation_id: 'cid', message_context: {},
                   model: 'x', request_type: 'chat',
                   error: { code: 'test', message: 'test' })
      end.not_to raise_error
    end

    it 'does nothing when reply_to is nil' do
      allow(described_class).to receive(:publish_error).and_call_original
      allow(Legion::LLM::Fleet::Error).to receive(:new)

      fleet.send(:publish_error,
                 reply_to: nil, correlation_id: 'cid', message_context: {},
                 model: 'x', request_type: 'chat',
                 error: { code: 'test', message: 'test' })
      expect(Legion::LLM::Fleet::Error).not_to have_received(:new)
    end
  end
end

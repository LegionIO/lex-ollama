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

    # Suppress reply publishing in all tests unless specifically testing it
    stub_const('Legion::Transport', double('Legion::Transport'))
    allow(described_class).to receive(:publish_reply)
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
      it 'calls publish_reply' do
        allow(described_class).to receive(:publish_reply).and_call_original
        allow(described_class).to receive(:publish_reply)
        fleet.handle_request(model: 'nomic-embed-text', request_type: 'embed',
                             input: 'hi', reply_to: 'agent.caller', correlation_id: 'cid-1')
        expect(described_class).to have_received(:publish_reply).with(
          'agent.caller', 'cid-1', hash_including(model: 'nomic-embed-text')
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
end

# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Transport::Messages::LlmResponse do
  subject(:message_class) { described_class }

  let(:base_options) do
    {
      reply_to:       'agent.test-node',
      correlation_id: 'abc-123',
      result:         { 'embeddings' => [[0.1, 0.2]] },
      usage:          { input_tokens: 5, output_tokens: 0 },
      model:          'nomic-embed-text',
      status:         200
    }
  end

  describe '#routing_key' do
    it 'returns the reply_to value from options' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, base_options)
      expect(instance.routing_key).to eq('agent.test-node')
    end
  end

  describe '#encrypt?' do
    it 'returns false' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, base_options)
      expect(instance.encrypt?).to be(false)
    end
  end

  describe '#message' do
    subject(:msg) do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, base_options)
      instance.message
    end

    it 'includes the correlation_id' do
      expect(msg[:correlation_id]).to eq('abc-123')
    end

    it 'includes the result' do
      expect(msg[:result]).to eq('embeddings' => [[0.1, 0.2]])
    end

    it 'includes the usage' do
      expect(msg[:usage][:input_tokens]).to eq(5)
    end

    it 'includes the model' do
      expect(msg[:model]).to eq('nomic-embed-text')
    end

    it 'sets provider to ollama' do
      expect(msg[:provider]).to eq('ollama')
    end

    it 'includes the status' do
      expect(msg[:status]).to eq(200)
    end

    it 'defaults status to 200 when not provided' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, base_options.except(:status))
      expect(instance.message[:status]).to eq(200)
    end
  end
end

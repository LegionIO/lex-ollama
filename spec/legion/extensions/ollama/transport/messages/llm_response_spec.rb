# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Transport::Messages::LlmResponse do
  subject(:message_class) { described_class }

  it 'inherits from Legion::LLM::Fleet::Response' do
    expect(message_class.ancestors).to include(Legion::LLM::Fleet::Response)
  end

  describe '#app_id' do
    it 'returns lex-ollama' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, {})
      expect(instance.app_id).to eq('lex-ollama')
    end
  end

  describe '#type' do
    it 'returns llm.fleet.response' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, {})
      expect(instance.type).to eq('llm.fleet.response')
    end
  end

  describe '#routing_key' do
    it 'returns the reply_to value' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, { reply_to: 'llm.fleet.reply.abc' })
      expect(instance.routing_key).to eq('llm.fleet.reply.abc')
    end
  end

  describe '#priority' do
    it 'returns 0' do
      instance = message_class.allocate
      instance.instance_variable_set(:@options, {})
      expect(instance.priority).to eq(0)
    end
  end
end

# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Transport::Exchanges::LlmRequest do
  subject(:exchange_class) { described_class }

  it 'is a subclass of Legion::LLM::Fleet::Exchange' do
    expect(exchange_class.ancestors).to include(Legion::LLM::Fleet::Exchange)
  end

  describe '#exchange_name' do
    it 'returns llm.request' do
      instance = exchange_class.allocate
      expect(instance.exchange_name).to eq('llm.request')
    end
  end

  describe '#default_type' do
    it 'returns topic' do
      instance = exchange_class.allocate
      expect(instance.default_type).to eq('topic')
    end
  end
end

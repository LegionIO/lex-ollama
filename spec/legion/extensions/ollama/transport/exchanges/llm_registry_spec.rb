# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Transport::Exchanges::LlmRegistry do
  subject(:exchange_class) { described_class }

  describe '#exchange_name' do
    it 'declares the llm.registry exchange' do
      instance = exchange_class.allocate

      expect(instance.exchange_name).to eq('llm.registry')
    end
  end

  describe '#default_type' do
    it 'uses the transport topic default' do
      instance = exchange_class.allocate

      expect(instance.default_type).to eq('topic')
    end
  end
end

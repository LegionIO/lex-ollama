# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Transport::Queues::ModelRequest do
  subject(:queue_class) { described_class }

  it 'is a subclass of Legion::Transport::Queue' do
    expect(queue_class.ancestors).to include(Legion::Transport::Queue)
  end

  describe '#queue_name' do
    it 'builds the correct name for an embed queue' do
      instance = queue_class.allocate
      instance.instance_variable_set(:@request_type, 'embed')
      instance.instance_variable_set(:@model, 'nomic-embed-text')
      expect(instance.queue_name).to eq('llm.request.ollama.embed.nomic-embed-text')
    end

    it 'builds the correct name for a chat queue' do
      instance = queue_class.allocate
      instance.instance_variable_set(:@request_type, 'chat')
      instance.instance_variable_set(:@model, 'llama3.2')
      expect(instance.queue_name).to eq('llm.request.ollama.chat.llama3.2')
    end

    it 'builds the correct name for a generate queue' do
      instance = queue_class.allocate
      instance.instance_variable_set(:@request_type, 'generate')
      instance.instance_variable_set(:@model, 'llama3.2')
      expect(instance.queue_name).to eq('llm.request.ollama.generate.llama3.2')
    end
  end

  describe 'model name sanitisation' do
    it 'converts colons to dots in the model name' do
      instance = queue_class.allocate
      instance.instance_variable_set(:@request_type, 'chat')
      instance.instance_variable_set(:@model, instance.send(:sanitise_model, 'qwen3.5:27b'))
      expect(instance.queue_name).to eq('llm.request.ollama.chat.qwen3.5.27b')
    end

    it 'sanitises a colon-containing model name during construction logic' do
      # Test the private sanitise_model method directly
      instance = queue_class.allocate
      sanitised = instance.send(:sanitise_model, 'qwen3.5:27b')
      expect(sanitised).to eq('qwen3.5.27b')
    end

    it 'leaves names without colons unchanged' do
      instance = queue_class.allocate
      sanitised = instance.send(:sanitise_model, 'nomic-embed-text')
      expect(sanitised).to eq('nomic-embed-text')
    end
  end

  describe '#queue_options' do
    it 'returns durable: true' do
      instance = queue_class.allocate
      expect(instance.queue_options[:durable]).to be(true)
    end

    it 'specifies quorum queue type' do
      instance = queue_class.allocate
      expect(instance.queue_options.dig(:arguments, :'x-queue-type')).to eq('quorum')
    end
  end
end

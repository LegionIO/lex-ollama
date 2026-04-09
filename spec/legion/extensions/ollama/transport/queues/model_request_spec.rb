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
    let(:instance) do
      q = queue_class.allocate
      q.instance_variable_set(:@request_type, 'embed')
      q.instance_variable_set(:@model, 'nomic-embed-text')
      q
    end

    it 'is not durable' do
      expect(instance.queue_options[:durable]).to be(false)
    end

    it 'is auto-delete' do
      expect(instance.queue_options[:auto_delete]).to be(true)
    end

    it 'sets x-max-priority to 10' do
      expect(instance.queue_options.dig(:arguments, 'x-max-priority')).to eq(10)
    end

    it 'does not set x-queue-type quorum' do
      expect(instance.queue_options.dig(:arguments, :'x-queue-type')).to be_nil
    end
  end

  describe '#dlx_enabled' do
    it 'returns false' do
      instance = queue_class.allocate
      expect(instance.dlx_enabled).to be(false)
    end
  end
end

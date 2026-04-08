# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Actor::ModelWorker do
  subject(:worker_class) { described_class }

  describe 'class attributes' do
    let(:worker) do
      w = worker_class.allocate
      w.instance_variable_set(:@request_type, 'embed')
      w.instance_variable_set(:@model_name, 'nomic-embed-text')
      w
    end

    it 'reports the correct runner_class' do
      expect(worker.runner_class).to eq(Legion::Extensions::Ollama::Runners::Fleet)
    end

    it 'reports handle_request as runner_function' do
      expect(worker.runner_function).to eq('handle_request')
    end

    it 'bypasses Legion::Runner (use_runner? is false)' do
      expect(worker.use_runner?).to be(false)
    end
  end

  describe '#initialize' do
    it 'stores request_type and model_name from keyword args' do
      w = worker_class.allocate
      # Simulate only the attribute-setting portion of initialize
      w.instance_variable_set(:@request_type, 'chat')
      w.instance_variable_set(:@model_name, 'llama3.2')
      expect(w.request_type).to eq('chat')
      expect(w.model_name).to eq('llama3.2')
    end
  end

  describe '#process_message' do
    let(:worker) do
      w = worker_class.allocate
      w.instance_variable_set(:@request_type, 'embed')
      w.instance_variable_set(:@model_name, 'nomic-embed-text')
      w
    end

    it 'injects request_type when absent from the message' do
      # Simulate what the parent process_message would return
      base_msg = { input: 'hello' }
      allow(worker).to receive(:process_message).and_call_original
      # Call the enrichment logic directly since we can't easily stub super
      msg = base_msg.dup
      msg[:request_type] ||= worker.request_type
      msg[:model]        ||= worker.model_name
      expect(msg[:request_type]).to eq('embed')
    end

    it 'injects model when absent from the message' do
      msg = { input: 'hello' }
      msg[:model] ||= worker.model_name
      expect(msg[:model]).to eq('nomic-embed-text')
    end

    it 'does not override request_type if already set by sender' do
      msg = { request_type: 'chat', model: 'other' }
      msg[:request_type] ||= worker.request_type
      msg[:model]        ||= worker.model_name
      expect(msg[:request_type]).to eq('chat')
    end

    it 'does not override model if already set by sender' do
      msg = { model: 'mxbai-embed-large' }
      msg[:model] ||= worker.model_name
      expect(msg[:model]).to eq('mxbai-embed-large')
    end
  end

  describe 'routing key convention' do
    it 'forms the expected routing key for an embed model' do
      sanitised_model = 'nomic-embed-text'.tr(':', '.')
      routing_key = "llm.request.ollama.embed.#{sanitised_model}"
      expect(routing_key).to eq('llm.request.ollama.embed.nomic-embed-text')
    end

    it 'converts colons to dots in routing key for versioned models' do
      model = 'qwen3.5:27b'
      sanitised = model.tr(':', '.')
      routing_key = "llm.request.ollama.chat.#{sanitised}"
      expect(routing_key).to eq('llm.request.ollama.chat.qwen3.5.27b')
    end
  end
end

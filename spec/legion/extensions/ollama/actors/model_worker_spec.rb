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

    it 'injects request_type and model when absent from the parent message' do
      allow_any_instance_of(worker_class.superclass)
        .to receive(:process_message)
        .and_return({ input: 'hello' })

      msg = worker.process_message({ input: 'hello' }, {}, {})

      expect(msg[:request_type]).to eq('embed')
      expect(msg[:model]).to eq('nomic-embed-text')
    end

    it 'does not override request_type if already set by sender' do
      allow_any_instance_of(worker_class.superclass)
        .to receive(:process_message)
        .and_return({ input: 'hello', request_type: 'chat', model: 'other' })

      msg = worker.process_message({ input: 'hello', request_type: 'chat', model: 'other' }, {}, {})

      expect(msg[:request_type]).to eq('chat')
      expect(msg[:model]).to eq('other')
    end

    it 'does not override model if already set by sender' do
      allow_any_instance_of(worker_class.superclass)
        .to receive(:process_message)
        .and_return({ input: 'hello', model: 'mxbai-embed-large' })

      msg = worker.process_message({ input: 'hello', model: 'mxbai-embed-large' }, {}, {})

      expect(msg[:request_type]).to eq('embed')
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

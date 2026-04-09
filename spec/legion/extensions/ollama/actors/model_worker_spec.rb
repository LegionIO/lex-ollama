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
      w.instance_variable_set(:@request_type, 'chat')
      w.instance_variable_set(:@model_name, 'llama3.2')
      expect(w.request_type).to eq('chat')
      expect(w.model_name).to eq('llama3.2')
    end
  end

  describe '#prefetch' do
    it 'returns 1' do
      worker = worker_class.allocate
      expect(worker.prefetch).to eq(1)
    end
  end

  describe '#consumer_priority' do
    context 'when Legion::Settings is not defined' do
      it 'returns 0' do
        worker = worker_class.allocate
        expect(worker.consumer_priority).to eq(0)
      end
    end

    context 'when Legion::Settings is defined' do
      before do
        stub_const('Legion::Settings', double('Legion::Settings'))
        allow(Legion::Settings).to receive(:dig)
          .with(:ollama, :fleet, :consumer_priority)
          .and_return(10)
      end

      it 'returns the configured value' do
        worker = worker_class.allocate
        expect(worker.consumer_priority).to eq(10)
      end
    end

    context 'when setting is nil' do
      before do
        stub_const('Legion::Settings', double('Legion::Settings'))
        allow(Legion::Settings).to receive(:dig)
          .with(:ollama, :fleet, :consumer_priority)
          .and_return(nil)
      end

      it 'returns 0' do
        worker = worker_class.allocate
        expect(worker.consumer_priority).to eq(0)
      end
    end
  end

  describe '#subscribe_options' do
    it 'includes x-priority argument' do
      worker = worker_class.allocate
      opts = worker.subscribe_options
      expect(opts[:arguments]['x-priority']).to eq(0)
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

    it 'injects message_context as empty hash when absent' do
      allow_any_instance_of(worker_class.superclass)
        .to receive(:process_message)
        .and_return({ input: 'hello' })

      msg = worker.process_message({ input: 'hello' }, {}, {})
      expect(msg[:message_context]).to eq({})
    end

    it 'does not overwrite an existing message_context' do
      ctx = { conversation_id: 'conv_123', request_id: 'req_abc' }
      allow_any_instance_of(worker_class.superclass)
        .to receive(:process_message)
        .and_return({ input: 'hello', message_context: ctx })

      msg = worker.process_message({ input: 'hello', message_context: ctx }, {}, {})
      expect(msg[:message_context]).to eq(ctx)
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

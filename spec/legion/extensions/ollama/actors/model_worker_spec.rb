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
      w.instance_variable_set(:@context_window, 32_768)
      expect(w.request_type).to eq('chat')
      expect(w.model_name).to eq('llama3.2')
      expect(w.context_window).to eq(32_768)
    end
  end

  describe '#prefetch' do
    it 'returns 1' do
      worker = worker_class.allocate
      expect(worker.prefetch).to eq(1)
    end
  end

  describe '#endpoint_polling?' do
    it 'defaults to basic_get polling' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return({})

      expect(worker.endpoint_polling?).to be(true)
    end

    it 'allows subscription scheduler mode for GPU workers' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return({ fleet: { scheduler: :subscription } })

      expect(worker.endpoint_polling?).to be(false)
    end
  end

  describe '#consumer_priority' do
    context 'when no fleet priority is configured' do
      it 'returns 0' do
        worker = worker_class.allocate
        allow(worker).to receive(:settings).and_return({})
        expect(worker.consumer_priority).to eq(0)
      end
    end

    context 'when fleet priority is configured' do
      it 'returns the configured value' do
        worker = worker_class.allocate
        allow(worker).to receive(:settings).and_return({ fleet: { consumer_priority: 10 } })
        expect(worker.consumer_priority).to eq(10)
      end
    end

    context 'when fleet priority setting is nil' do
      it 'returns 0' do
        worker = worker_class.allocate
        allow(worker).to receive(:settings).and_return({ fleet: { consumer_priority: nil } })
        expect(worker.consumer_priority).to eq(0)
      end
    end
  end

  describe 'fleet lane TTL settings' do
    it 'uses default queue expiration and message TTL' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return({})

      expect(worker.queue_expires_ms).to eq(60_000)
      expect(worker.message_ttl_ms).to eq(120_000)
    end

    it 'uses configured queue expiration and message TTL' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return({ fleet: { queue_expires_ms: 15_000, message_ttl_ms: 5_000 } })

      expect(worker.queue_expires_ms).to eq(15_000)
      expect(worker.message_ttl_ms).to eq(5_000)
    end
  end

  describe 'fleet lane queue guardrail settings' do
    it 'uses default queue backpressure and delivery guardrails' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return({})

      expect(worker.queue_max_length).to eq(100)
      expect(worker.delivery_limit).to eq(3)
      expect(worker.consumer_ack_timeout_ms).to eq(300_000)
    end

    it 'uses configured queue backpressure and delivery guardrails' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return(
        {
          fleet: {
            queue_max_length:        25,
            delivery_limit:          2,
            consumer_ack_timeout_ms: 60_000
          }
        }
      )

      expect(worker.queue_max_length).to eq(25)
      expect(worker.delivery_limit).to eq(2)
      expect(worker.consumer_ack_timeout_ms).to eq(60_000)
    end

    it 'uses string-keyed queue backpressure and delivery guardrails' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return(
        {
          'fleet' => {
            'queue_max_length'        => 25,
            'delivery_limit'          => 2,
            'consumer_ack_timeout_ms' => 60_000
          }
        }
      )

      expect(worker.queue_max_length).to eq(25)
      expect(worker.delivery_limit).to eq(2)
      expect(worker.consumer_ack_timeout_ms).to eq(60_000)
    end
  end

  describe '#subscribe_options' do
    it 'includes x-priority argument' do
      worker = worker_class.allocate
      allow(worker).to receive(:settings).and_return({})
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

  describe '#lane_key' do
    it 'forms the shared fleet lane key for an embed model' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'embed')
      worker.instance_variable_set(:@model_name, 'nomic-embed-text:latest')

      expect(worker.lane_key).to eq('llm.fleet.embed.nomic-embed-text-latest')
    end

    it 'forms the shared fleet lane key for inference with context' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'chat')
      worker.instance_variable_set(:@model_name, 'qwen3.5:27b')
      worker.instance_variable_set(:@context_window, 32_768)

      expect(worker.lane_key).to eq('llm.fleet.inference.qwen3-5-27b.ctx32768')
    end

    it 'forms an exact offering lane key compatible with legion-llm offering routing' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'chat')
      worker.instance_variable_set(:@model_name, 'qwen3.6:27b')
      worker.instance_variable_set(:@lane_style, 'offering')
      worker.instance_variable_set(:@offering_instance_id, 'macbook-m4')

      expect(worker.lane_key).to eq('llm.fleet.offering.macbook-m4.qwen3-6-27b.inference')
    end

    it 'uses embed as the exact offering operation for embedding workers' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'embed')
      worker.instance_variable_set(:@model_name, 'nomic-embed-text:latest')
      worker.instance_variable_set(:@lane_style, 'offering')
      worker.instance_variable_set(:@offering_instance_id, 'gpu-01')

      expect(worker.lane_key).to eq('llm.fleet.offering.gpu-01.nomic-embed-text-latest.embed')
    end

    it 'aliases routing_key to the selected lane key' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'embed')
      worker.instance_variable_set(:@model_name, 'nomic-embed-text')

      expect(worker.routing_key).to eq('llm.fleet.embed.nomic-embed-text')
    end

    it 'collapses repeated punctuation when sanitizing model lane names' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'chat')
      worker.instance_variable_set(:@model_name, '---Qwen///3.5:::27B---')
      worker.instance_variable_set(:@context_window, 32_768)

      expect(worker.routing_key).to eq('llm.fleet.inference.qwen-3-5-27b.ctx32768')
    end
  end

  describe '#queue' do
    it 'builds a durable fleet lane queue bound to the lane routing key' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'chat')
      worker.instance_variable_set(:@model_name, 'qwen3.5:27b')
      worker.instance_variable_set(:@context_window, 32_768)

      queue_class = worker.queue
      queue = queue_class.allocate

      expect(queue.queue_name).to eq('llm.fleet.inference.qwen3-5-27b.ctx32768')
      expect(queue.queue_options[:durable]).to be(true)
      expect(queue.queue_options[:auto_delete]).to be(false)
      expect(queue.queue_options[:arguments]['x-queue-type']).to eq('quorum')
    end

    it 'builds a durable quorum lane queue with expiry, TTL, and backpressure settings' do
      worker = worker_class.allocate
      worker.instance_variable_set(:@request_type, 'embed')
      worker.instance_variable_set(:@model_name, 'nomic-embed-text')
      allow(worker).to receive(:settings).and_return(
        {
          fleet: {
            queue_expires_ms:        15_000,
            message_ttl_ms:          5_000,
            queue_max_length:        25,
            delivery_limit:          2,
            consumer_ack_timeout_ms: 60_000
          }
        }
      )

      queue_class = worker.queue
      queue_instance = queue_class.allocate
      options = queue_instance.queue_options

      expect(queue_instance.queue_name).to eq('llm.fleet.embed.nomic-embed-text')
      expect(options[:durable]).to eq(true)
      expect(options[:auto_delete]).to eq(false)
      expect(options[:arguments]['x-queue-type']).to eq('quorum')
      expect(options[:arguments]['x-queue-leader-locator']).to eq('balanced')
      expect(options[:arguments]['x-expires']).to eq(15_000)
      expect(options[:arguments]['x-message-ttl']).to eq(5_000)
      expect(options[:arguments]['x-overflow']).to eq('reject-publish')
      expect(options[:arguments]['x-max-length']).to eq(25)
      expect(options[:arguments]['x-delivery-limit']).to eq(2)
      expect(options[:arguments]['x-consumer-timeout']).to eq(60_000)
      expect(queue_instance.dlx_enabled).to eq(false)
    end

    it 'builds the same lane queue class from class-level arguments' do
      queue_class = worker_class.queue_class_for(
        request_type:   'chat',
        model:          'Qwen3.5:27B',
        context_window: 32_768,
        queue_config:   { queue_expires_ms: 15_000, message_ttl_ms: 5_000 }
      )
      queue_instance = queue_class.allocate

      expect(queue_instance.queue_name).to eq('llm.fleet.inference.qwen3-5-27b.ctx32768')
      expect(queue_instance.queue_options[:arguments]['x-queue-type']).to eq('quorum')
      expect(queue_instance.queue_options[:arguments]['x-expires']).to eq(15_000)
      expect(queue_instance.queue_options[:arguments]['x-message-ttl']).to eq(5_000)
    end

    it 'builds offering lane queues from class-level arguments when requested' do
      queue_class = worker_class.queue_class_for(
        request_type:         'chat',
        model:                'Qwen3.5:27B',
        lane_style:           :offering,
        offering_instance_id: 'macbook-m4',
        queue_config:         { queue_expires_ms: 15_000 }
      )
      queue_instance = queue_class.allocate

      expect(queue_instance.queue_name).to eq('llm.fleet.offering.macbook-m4.qwen3-5-27b.inference')
      expect(queue_instance.queue_options[:arguments]['x-expires']).to eq(15_000)
    end
  end
end

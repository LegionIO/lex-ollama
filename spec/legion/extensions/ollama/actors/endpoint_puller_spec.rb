# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Actor::EndpointPuller do
  subject(:puller) { described_class.allocate }

  let(:settings) do
    {
      fleet:         {
        scheduler: :basic_get,
        endpoint:  {
          enabled:                        true,
          idle_backoff_ms:                2_000,
          max_consecutive_pulls_per_lane: 0
        }
      },
      subscriptions: [
        { type: 'chat', model: 'qwen3.6:27b', context_window: 32_768 },
        { type: 'embed', model: 'nomic-embed-text' },
        { type: 'chat', model: 'qwen3.6:35b', context_window: 65_536 }
      ]
    }
  end

  before do
    allow(puller).to receive(:settings).and_return(settings)
    stub_const('FakeQueue', Class.new do
      attr_reader :acked, :rejected, :pop_count

      def initialize(messages)
        @messages = messages
        @acked = []
        @rejected = []
        @pop_count = 0
      end

      def pop(manual_ack:)
        raise ArgumentError, 'manual_ack must be true' unless manual_ack

        @pop_count += 1
        @messages.shift || [nil, nil, nil]
      end

      def acknowledge(tag)
        @acked << tag
      end

      def reject(tag, requeue: false)
        @rejected << [tag, requeue]
      end
    end)
  end

  describe '#enabled?' do
    it 'is enabled when fleet scheduler is basic_get, endpoint is enabled, and subscriptions exist' do
      expect(puller.enabled?).to be(true)
    end

    it 'is disabled when endpoint fleet participation is not enabled' do
      settings[:fleet][:endpoint][:enabled] = false

      expect(puller.enabled?).to be(false)
    end

    it 'is disabled when the scheduler is not basic_get' do
      settings[:fleet][:scheduler] = :subscribe

      expect(puller.enabled?).to be(false)
    end

    it 'supports string-keyed JSON settings' do
      allow(puller).to receive(:settings).and_return(
        {
          'fleet'         => { 'scheduler' => 'basic_get', 'endpoint' => { 'enabled' => true } },
          'subscriptions' => [{ 'type' => 'embed', 'model' => 'nomic-embed-text' }]
        }
      )

      expect(puller.enabled?).to be(true)
    end
  end

  describe '#time' do
    it 'uses the configured idle backoff in seconds' do
      expect(puller.time).to eq(2.0)
    end
  end

  describe '#empty_lane_backoff_seconds' do
    it 'uses the configured empty lane backoff in seconds' do
      settings[:fleet][:endpoint][:empty_lane_backoff_ms] = 500

      expect(puller.empty_lane_backoff_seconds).to eq(0.5)
    end
  end

  describe '#ordered_subscriptions' do
    it 'prioritizes embeddings, then non-embedding lanes by ascending context size' do
      expect(puller.ordered_subscriptions.map { |sub| [sub[:type], sub[:model]] }).to eq(
        [
          ['embed', 'nomic-embed-text'],
          ['chat', 'qwen3.6:27b'],
          ['chat', 'qwen3.6:35b']
        ]
      )
    end
  end

  describe '#queue_for' do
    it 'caches separate queues for the same model with different context lanes' do
      first = { type: 'chat', model: 'qwen3.6:27b', context_window: 32_768 }
      second = { type: 'chat', model: 'qwen3.6:27b', context_window: 65_536 }
      calls = []

      allow(Legion::Extensions::Ollama::Actor::ModelWorker).to receive(:queue_class_for) do |**kwargs|
        calls << kwargs
        Class.new do
          define_method(:queue_name) { "queue.ctx#{kwargs[:context_window]}" }
        end
      end

      expect(puller.queue_for(first).queue_name).to eq('queue.ctx32768')
      expect(puller.queue_for(second).queue_name).to eq('queue.ctx65536')
      expect(calls.map { |call| call[:context_window] }).to eq([32_768, 65_536])
    end

    it 'passes string-keyed fleet queue settings to lane queue classes' do
      allow(puller).to receive(:settings).and_return(
        {
          'fleet'         => {
            'scheduler'               => 'basic_get',
            'queue_expires_ms'        => 10_000,
            'message_ttl_ms'          => 5_000,
            'queue_max_length'        => 7,
            'delivery_limit'          => 2,
            'consumer_ack_timeout_ms' => 30_000,
            'endpoint'                => { 'enabled' => true }
          },
          'subscriptions' => [{ 'type' => 'embed', 'model' => 'nomic-embed-text' }]
        }
      )

      expect(Legion::Extensions::Ollama::Actor::ModelWorker).to receive(:queue_class_for).with(
        request_type:   'embed',
        model:          'nomic-embed-text',
        context_window: nil,
        queue_config:   {
          queue_expires_ms:        10_000,
          message_ttl_ms:          5_000,
          queue_max_length:        7,
          delivery_limit:          2,
          consumer_ack_timeout_ms: 30_000
        }
      ).and_return(Class.new)

      puller.queue_for(type: 'embed', model: 'nomic-embed-text')
    end
  end

  describe '#pull_one' do
    let(:delivery_info) { instance_double('DeliveryInfo', delivery_tag: 'tag-1', routing_key: 'llm.fleet.embed.nomic') }
    let(:metadata) { instance_double('Metadata', content_type: 'application/json', content_encoding: nil, headers: {}) }
    let(:payload) { Legion::JSON.dump({ input: 'hello' }) }
    let(:queue) { FakeQueue.new([[delivery_info, metadata, payload]]) }

    it 'dispatches one message and acknowledges it' do
      expect(Legion::Extensions::Ollama::Runners::Fleet)
        .to receive(:handle_request)
        .with(hash_including(input: 'hello', request_type: 'embed', model: 'nomic-embed-text'))

      pulled = puller.pull_one(queue, { type: 'embed', model: 'nomic-embed-text' })

      expect(pulled).to be(true)
      expect(queue.acked).to eq(['tag-1'])
      expect(queue.rejected).to eq([])
    end

    it 'returns false when the queue is empty' do
      empty_queue = FakeQueue.new([])

      expect(puller.pull_one(empty_queue, { type: 'embed', model: 'nomic-embed-text' })).to be(false)
    end

    it 'decrypts symmetric encrypted payloads with string-keyed headers' do
      stub_const('Legion::Crypt', Module.new)
      encrypted_metadata = instance_double(
        'Metadata',
        content_type:     'application/json',
        content_encoding: 'encrypted/cs',
        headers:          { 'iv' => 'iv-1' }
      )
      encrypted_queue = FakeQueue.new([[delivery_info, encrypted_metadata, 'ciphertext']])

      expect(Legion::Crypt).to receive(:decrypt).with('ciphertext', 'iv-1').and_return(payload)
      expect(Legion::Extensions::Ollama::Runners::Fleet)
        .to receive(:handle_request)
        .with(hash_including(input: 'hello', request_type: 'embed', model: 'nomic-embed-text'))

      expect(puller.pull_one(encrypted_queue, { type: 'embed', model: 'nomic-embed-text' })).to be(true)
    end
  end

  describe '#action' do
    it 'does not poll a lane again while its empty-lane backoff is active' do
      queue = FakeQueue.new([])
      allow(puller).to receive(:queue_for).and_return(queue)
      allow(puller).to receive(:ordered_subscriptions).and_return([{ type: 'embed', model: 'nomic-embed-text' }])
      allow(puller).to receive(:monotonic_time).and_return(100.0, 100.0, 100.1)

      puller.action
      puller.action

      expect(queue.pop_count).to eq(1)
    end
  end
end

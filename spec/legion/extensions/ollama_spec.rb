# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama do
  it 'has a version number' do
    expect(Legion::Extensions::Ollama::VERSION).not_to be_nil
  end

  it 'returns a valid semver string' do
    expect(Legion::Extensions::Ollama::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe '.default_settings' do
    it 'defaults endpoint fleet participation off with basic_get as the scheduler' do
      settings = described_class.default_settings

      expect(settings.dig(:fleet, :scheduler)).to eq(:basic_get)
      expect(settings.dig(:fleet, :endpoint, :enabled)).to be(false)
      expect(settings.dig(:fleet, :endpoint, :empty_lane_backoff_ms)).to eq(250)
    end

    it 'keeps exact offering lanes disabled by default' do
      settings = described_class.default_settings

      expect(settings.dig(:fleet, :offering_lanes, :enabled)).to be(false)
      expect(settings.dig(:fleet, :offering_lanes, :instance_id)).to be_nil
    end
  end

  describe '.valid_fleet_subscriptions' do
    it 'accepts string and symbol keyed subscription hashes' do
      subscriptions = [
        { type: 'embed', model: 'nomic-embed-text' },
        { 'type' => 'chat', 'model' => 'qwen3.6:27b' },
        { type: 'chat' }
      ]

      expect(described_class.valid_fleet_subscriptions(subscriptions).size).to eq(2)
    end
  end

  describe '.sorted_subscriptions' do
    it 'prioritizes embeddings before inference and smaller contexts before larger contexts' do
      subscriptions = [
        { type: :chat, model: 'large', context_window: 32_768 },
        { type: :embed, model: 'embedder' },
        { type: :chat, model: 'small', context_window: 8_192 }
      ]

      expect(described_class.sorted_subscriptions(subscriptions).map { |sub| sub[:model] })
        .to eq(%w[embedder small large])
    end
  end

  describe '.offering_instance_for' do
    it 'returns nil unless exact offering lanes are enabled' do
      allow(described_class).to receive(:settings).and_return({
                                                                fleet: {
                                                                  offering_lanes: {
                                                                    enabled:     false,
                                                                    instance_id: 'gpu-01'
                                                                  }
                                                                }
                                                              })

      expect(described_class.offering_instance_for({ type: :chat, model: 'qwen3.6:27b' })).to be_nil
    end

    it 'uses a subscription-specific provider instance before the global setting' do
      allow(described_class).to receive(:settings).and_return({
                                                                fleet: {
                                                                  offering_lanes: {
                                                                    enabled:     true,
                                                                    instance_id: 'gpu-01'
                                                                  }
                                                                }
                                                              })

      instance = described_class.offering_instance_for({
                                                         type:              :chat,
                                                         model:             'qwen3.6:27b',
                                                         provider_instance: 'macbook-m4'
                                                       })

      expect(instance).to eq('macbook-m4')
    end
  end

  describe '.register_model_worker' do
    after do
      described_class.instance_variable_set(:@actors, nil)
    end

    it 'registers shared and exact offering workers as separate actor entries' do
      described_class.instance_variable_set(:@actors, {})

      described_class.register_model_worker(request_type: :chat, model: 'qwen3.6:27b', context_window: 32_768)
      described_class.register_model_worker(
        request_type:         :chat,
        model:                'qwen3.6:27b',
        context_window:       32_768,
        lane_style:           :offering,
        offering_instance_id: 'macbook-m4'
      )

      actors = described_class.instance_variable_get(:@actors)
      expect(actors.keys).to contain_exactly(
        :model_worker_chat_qwen3_6_27b,
        :model_worker_offering_chat_qwen3_6_27b_macbook_m4
      )
    end
  end
end

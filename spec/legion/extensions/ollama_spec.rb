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
end

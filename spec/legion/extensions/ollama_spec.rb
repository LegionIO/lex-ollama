# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama do
  it 'has a version number' do
    expect(Legion::Extensions::Ollama::VERSION).not_to be_nil
  end

  it 'returns a valid semver string' do
    expect(Legion::Extensions::Ollama::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it 'defaults fleet endpoint scheduling to basic_get' do
    settings = described_class.default_settings

    expect(settings.dig(:fleet, :scheduler)).to eq(:basic_get)
    expect(settings.dig(:fleet, :endpoint, :empty_lane_backoff_ms)).to eq(250)
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
end

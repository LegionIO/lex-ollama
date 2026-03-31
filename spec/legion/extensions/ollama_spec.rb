# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama do
  it 'has a version number' do
    expect(Legion::Extensions::Ollama::VERSION).not_to be_nil
  end

  it 'returns a valid semver string' do
    expect(Legion::Extensions::Ollama::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end

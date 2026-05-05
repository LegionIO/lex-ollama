# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Transport::Messages::RegistryEvent do
  let(:event) do
    Legion::Extensions::Llm::Routing::RegistryEvent.available(
      {
        provider_family:   :ollama,
        provider_instance: :macbook_m4,
        transport:         :rabbitmq,
        model:             'qwen3.5:27b',
        usage_type:        :inference,
        capabilities:      %i[chat],
        limits:            { context_window: 32_768 }
      },
      lane: 'llm.fleet.inference.qwen3-5-27b.ctx32768'
    )
  end

  subject(:message) { described_class.new(event: event) }

  it 'publishes through the llm.registry exchange' do
    expect(message.exchange).to eq(Legion::Extensions::Ollama::Transport::Exchanges::LlmRegistry)
  end

  it 'routes by registry event type' do
    expect(message.routing_key).to eq('llm.registry.offering_available')
  end

  it 'uses the registry event wire type and lex-ollama app id' do
    expect(message.type).to eq('llm.registry.event')
    expect(message.app_id).to eq('lex-ollama')
  end

  it 'publishes as nonpersistent availability metadata' do
    expect(message.persistent).to be(false)
  end

  it 'serializes the lex-llm RegistryEvent envelope as the message body' do
    expect(message.message).to include(
      event_type: :offering_available,
      lane:       'llm.fleet.inference.qwen3-5-27b.ctx32768'
    )
    expect(message.message[:offering]).to include(
      provider_family:   :ollama,
      provider_instance: :macbook_m4,
      transport:         :rabbitmq,
      model:             'qwen3.5:27b',
      usage_type:        :inference,
      capabilities:      %i[chat],
      limits:            { context_window: 32_768 }
    )
  end
end

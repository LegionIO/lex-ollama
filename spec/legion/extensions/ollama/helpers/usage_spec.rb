# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Helpers::Usage do
  describe '.from_response' do
    it 'extracts usage from an Ollama response body' do
      body = {
        'prompt_eval_count'    => 26,
        'eval_count'           => 259,
        'total_duration'       => 10_706_818_083,
        'load_duration'        => 6_338_219_291,
        'prompt_eval_duration' => 130_079_000,
        'eval_duration'        => 4_232_710_000
      }

      result = described_class.from_response(body)
      expect(result).to eq({
                             input_tokens:         26,
                             output_tokens:        259,
                             total_duration:       10_706_818_083,
                             load_duration:        6_338_219_291,
                             prompt_eval_duration: 130_079_000,
                             eval_duration:        4_232_710_000
                           })
    end

    it 'returns zero-filled hash when body is nil' do
      expect(described_class.from_response(nil)).to eq(described_class::EMPTY_USAGE)
    end

    it 'returns zero-filled hash when body is not a Hash' do
      expect(described_class.from_response('string')).to eq(described_class::EMPTY_USAGE)
    end

    it 'defaults missing keys to 0' do
      body = { 'prompt_eval_count' => 10 }
      result = described_class.from_response(body)
      expect(result[:input_tokens]).to eq(10)
      expect(result[:output_tokens]).to eq(0)
      expect(result[:total_duration]).to eq(0)
    end

    it 'handles a response with no eval fields' do
      body = { 'model' => 'llama3.2', 'done' => true }
      result = described_class.from_response(body)
      expect(result).to eq(described_class::EMPTY_USAGE)
    end
  end

  describe 'EMPTY_USAGE' do
    it 'is frozen' do
      expect(described_class::EMPTY_USAGE).to be_frozen
    end

    it 'contains all expected keys' do
      expect(described_class::EMPTY_USAGE.keys).to contain_exactly(
        :input_tokens, :output_tokens, :total_duration,
        :load_duration, :prompt_eval_duration, :eval_duration
      )
    end
  end
end

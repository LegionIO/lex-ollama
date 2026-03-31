# frozen_string_literal: true

RSpec.describe Legion::Extensions::Ollama::Helpers::Errors do
  describe '.retryable?' do
    it 'returns true for Faraday::TimeoutError' do
      expect(described_class.retryable?(Faraday::TimeoutError.new)).to be(true)
    end

    it 'returns true for Faraday::ConnectionFailed' do
      expect(described_class.retryable?(Faraday::ConnectionFailed.new('conn refused'))).to be(true)
    end

    it 'returns false for other errors' do
      expect(described_class.retryable?(StandardError.new)).to be(false)
    end
  end

  describe '.with_retry' do
    it 'returns the block result on success' do
      result = described_class.with_retry { 42 }
      expect(result).to eq(42)
    end

    it 'retries on TimeoutError and succeeds' do
      attempts = 0
      result = described_class.with_retry(max_retries: 3) do
        attempts += 1
        raise Faraday::TimeoutError if attempts < 2

        'ok'
      end
      expect(result).to eq('ok')
      expect(attempts).to eq(2)
    end

    it 'retries on ConnectionFailed and succeeds' do
      attempts = 0
      result = described_class.with_retry(max_retries: 3) do
        attempts += 1
        raise Faraday::ConnectionFailed, 'refused' if attempts < 2

        'ok'
      end
      expect(result).to eq('ok')
      expect(attempts).to eq(2)
    end

    it 'raises after exceeding max retries' do
      expect do
        described_class.with_retry(max_retries: 2) { raise Faraday::TimeoutError }
      end.to raise_error(Faraday::TimeoutError)
    end

    it 'does not retry non-retryable errors' do
      attempts = 0
      expect do
        described_class.with_retry do
          attempts += 1
          raise ArgumentError, 'bad'
        end
      end.to raise_error(ArgumentError)
      expect(attempts).to eq(1)
    end
  end
end

# frozen_string_literal: true

require "json"

module TimekeepingContract
  # In-memory idempotency receipts (contracts/timekeeping/idempotency.yml).
  # A receipt is stored only for a 2xx answer, so a retry after an error,
  # a 409 included, is evaluated again.
  class IdempotencyReceipts
    SUCCESS = (200..299)

    # Which request facts a receipt is keyed by. The contract scopes it by
    # company, actor, operation and key, so no other caller can match it.
    SCOPED_RECEIPT_KEY = ->(company_scope:, actor:, operation:, key:) { [company_scope, actor, operation, key] }

    def initialize(receipt_key: SCOPED_RECEIPT_KEY, reject_reused_key: true)
      @contract = TimekeepingContract.load(:idempotency)
      @receipt_key = receipt_key
      @reject_reused_key = reject_reused_key
      @receipts = {}
    end

    # Returns the stored answer for a replay of the same request, the
    # key_reused error for the same key with a new body, and otherwise the
    # answer the block evaluates. A request without a key is always evaluated.
    def answer(company_scope:, actor:, operation:, key:, body:)
      return yield if key.nil?

      receipt_key = @receipt_key.call(company_scope:, actor:, operation:, key:)
      fingerprint = JSON.generate(body)
      stored = @receipts[receipt_key]
      if stored
        return stored.fetch(:response) if stored.fetch(:fingerprint) == fingerprint
        return Wire.error(@contract, "key_reused") if @reject_reused_key
      end

      response = yield
      @receipts[receipt_key] = { fingerprint:, response: } if SUCCESS.cover?(response.status)
      response
    end
  end
end

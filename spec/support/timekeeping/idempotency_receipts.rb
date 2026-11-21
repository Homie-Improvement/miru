# frozen_string_literal: true

require "json"

module TimekeepingContract
  # In-memory idempotency receipts (contracts/timekeeping/idempotency.yml).
  # A receipt is stored only for an answer in the contract's stored_statuses
  # class (2xx), so a retry after an error, a 409 included, is evaluated again.
  # A successful answer that changed nothing is stored only for an operation
  # the contract lists in unchanged_stored_operations; any other is evaluated
  # again on retry.
  class IdempotencyReceipts
    # What an answer block returns, in place of the bare response, for a
    # successful answer that changed nothing.
    Unchanged = Data.define(:response)

    # Which request facts a receipt is keyed by. The contract scopes it by
    # company, actor, operation and key, so no other caller can match it.
    SCOPED_RECEIPT_KEY = ->(company_scope:, actor:, operation:, key:) { [company_scope, actor, operation, key] }

    # Whether an answer is stored: stored_statuses names a status class such as "2xx".
    STORE_CONTRACT_STATUSES = ->(status:, stored_statuses:) { status.to_s.start_with?(stored_statuses.delete_suffix("xx")) }

    # Whether an answer that changed nothing is stored. An operation is its
    # route name followed by its target, such as "detach_entries 77", and the
    # contract lists route names.
    STORE_CONTRACT_UNCHANGED = lambda do |operation:, unchanged_stored_operations:|
      unchanged_stored_operations.include?(operation.split.first)
    end

    def initialize(receipt_key: SCOPED_RECEIPT_KEY, reject_reused_key: true, store_answer: STORE_CONTRACT_STATUSES,
                   store_unchanged: STORE_CONTRACT_UNCHANGED)
      @contract = TimekeepingContract.load(:idempotency)
      @receipt_key = receipt_key
      @reject_reused_key = reject_reused_key
      @store_answer = store_answer
      @store_unchanged = store_unchanged
      @receipts = {}
    end

    # Returns the stored answer for a replay of the same request, the
    # key_reused error for the same key with a new body, and otherwise the
    # answer the block evaluates. The block returns a response, or an
    # Unchanged holding one when the answer changed nothing. A request without
    # a key is always evaluated.
    def answer(company_scope:, actor:, operation:, key:, body:)
      return response_of(yield) if key.nil?

      receipt_key = @receipt_key.call(company_scope:, actor:, operation:, key:)
      fingerprint = JSON.generate(body)
      stored = @receipts[receipt_key]
      if stored
        return Response.new(status: stored.fetch(:status), body: Wire.copy(stored.fetch(:body))) if stored.fetch(:fingerprint) == fingerprint
        return Wire.error(@contract, "key_reused") if @reject_reused_key
      end

      evaluated = yield
      response = response_of(evaluated)
      if stored?(operation, response, unchanged: evaluated.is_a?(Unchanged))
        # A private copy, so a caller editing its answer cannot change what a replay returns.
        @receipts[receipt_key] = { fingerprint:, status: response.status, body: Wire.copy(response.body) }
      end
      response
    end

    private

      def response_of(evaluated)
        evaluated.is_a?(Unchanged) ? evaluated.response : evaluated
      end

      def stored?(operation, response, unchanged:)
        return false unless @store_answer.call(status: response.status, stored_statuses: @contract.fetch("stored_statuses"))

        !unchanged ||
          @store_unchanged.call(operation:, unchanged_stored_operations: @contract.fetch("unchanged_stored_operations"))
      end
  end
end

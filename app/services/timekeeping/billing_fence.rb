# frozen_string_literal: true

module Timekeeping
  # Refuses invoice, line-item, invoice-tax and payment writes while a
  # Timekeeping handoff is in progress (docs/architecture/timekeeping-soa.md
  # section 10.1). The handoff compares a financial snapshot taken before its
  # pause with one taken after it (section 10.4); a billing write between the
  # two would make that comparison meaningless.
  #
  # Each billing write transaction takes FOR SHARE on the single ownership
  # row and reads handoff_step under that lock. The handoff's first step
  # updates the row, so it waits for every billing transaction already
  # holding the lock, and every billing transaction that starts after it
  # reads the new handoff_step and is refused.
  class BillingFence
    # Raised when a billing write is refused. Retryable: the write succeeds
    # once the handoff ends. Rendered as 503 ownership_moving.
    class OwnershipMoving < StandardError
      def initialize(message = "ownership_moving")
        super
      end
    end

    # Raised when the fence is called with no open transaction: a programming
    # error, never a refusal to show a caller.
    class TransactionRequired < StandardError; end

    # How long a refused caller is told to wait before retrying.
    RETRY_AFTER_SECONDS = 5

    # Runs the block in the billing transaction, after the ownership check,
    # and returns its value. Joins an outer transaction when one is open, so a
    # refusal rolls back every write the outer transaction made.
    def self.transaction(&block)
      ActiveRecord::Base.transaction do
        admit!
        block.call
      end
    end

    # Takes the share lock and refuses when a handoff is in progress. A missing
    # row also refuses: lost ownership state must not let billing writes
    # through, nor surface as a 404 for the caller's invoice.
    #
    # Must run inside a transaction, because outside one the share lock is
    # released as soon as the read ends and protects nothing.
    def self.admit!
      unless ActiveRecord::Base.connection.transaction_open?
        raise TransactionRequired, "the billing fence must run inside a transaction"
      end

      ownership = TimekeepingOwnership.lock("FOR SHARE").find_by(id: TimekeepingOwnership::SINGLETON_ID)
      raise OwnershipMoving if ownership.nil? || ownership.handoff_step.present?

      nil
    end
  end
end

# frozen_string_literal: true

module Invoices
  # Errors raised by the invoice operation coordinator, its delivery and its
  # adapter selection. Every one raised inside an invoice transaction unwinds
  # it, so the invoice change never commits after a failed reservation.
  module OperationErrors
    # The caller may try the same save again later and expect it to work.
    class Retryable < StandardError; end

    # The guarded update to `committed` changed no row: recovery already
    # failed the intent, so the invoice change must roll back.
    class IntentNotPending < Retryable
      def initialize(message = "intent_not_pending")
        super
      end
    end

    # No reservation adapter is registered for the current entry owner yet.
    class AdapterNotAvailable < Retryable
      def initialize(message = "adapter_not_available")
        super
      end
    end

    # The adapter answered `retryable` to prepare.
    class PrepareRetryable < Retryable
      def initialize(message = "prepare_retryable")
        super
      end
    end

    # The adapter answered mark_billed with neither `committed` nor
    # `refused`, so the entries may still be unbilled and the invoice must
    # not be sent.
    class BillingRetryable < Retryable
      def initialize(message = "billing_retryable")
        super
      end
    end

    # The adapter answered prepare with a terminal state (`committed` or
    # `aborted`); the save never re-runs the change on such an answer.
    class ReconciliationRequired < Retryable
      def initialize(message = "reconciliation_required")
        super
      end
    end

    # The adapter refused the reservation. Carries the outcome so the caller
    # can read its conflicts.
    class Refused < StandardError
      attr_reader :outcome

      def initialize(outcome = nil, message = "reservation_refused")
        @outcome = outcome
        super(message)
      end
    end

    # The coordinator was called with no open transaction: a programming
    # error, never a refusal to show a caller.
    class NoTransaction < StandardError
      def initialize(message = "invoice_transaction_required")
        super
      end
    end
  end
end

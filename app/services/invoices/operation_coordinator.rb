# frozen_string_literal: true

module Invoices
  # Runs one invoice save through the reservation port in the order
  # docs/architecture/timekeeping-soa.md section 9.2 sets:
  #
  # 1. Under the invoice's advisory lock, write the pending intent on its own
  #    connection, so it is committed before the store is asked to prepare and
  #    survives any rollback of the invoice transaction.
  # 2. Ask the adapter to prepare.
  # 3. On `prepared`, in the invoice transaction: move the intent to
  #    `committed` only while it is still pending, write the commit outbox row
  #    and the holding. All three commit or roll back with the invoice change.
  # 4. On every other answer, raise, so the invoice transaction rolls back;
  #    once it has, mark the intent `failed` (same guard) and write the abort
  #    outbox row in one new transaction.
  #
  # After the invoice transaction ends, the settlement row is delivered once
  # inline; a failed delivery is left for the invoice_operations worker. A
  # `refused` answer is also recorded for the prepare_refusal alert once the
  # outermost transaction ends, whether it committed or rolled back.
  class OperationCoordinator
    # What each prepare answer leads to. Only `prepared` settles the save;
    # every other answer raises its error through the invoice transaction. A
    # terminal answer never re-runs the change.
    PREPARE_ROUTES = {
      "prepared" => :settle,
      "refused" => OperationErrors::Refused,
      "retryable" => OperationErrors::PrepareRetryable,
      "committed" => OperationErrors::ReconciliationRequired,
      "aborted" => OperationErrors::ReconciliationRequired
    }.freeze

    def initialize(reservations:)
      @reservations = reservations
    end

    # Must run inside the caller's open invoice transaction. Returns the
    # prepared outcome; raises on every other answer.
    def call(request, holding:)
      connection = ApplicationRecord.connection
      raise OperationErrors::NoTransaction unless connection.transaction_open?

      lock_current_generation!(connection, request)
      write_pending_intent(request)

      settlement = { commit_item_id: nil }
      register_settlement_callbacks(connection, request, settlement)

      outcome = reservations.prepare(request)
      settlement[:refusal] = outcome if outcome.state == "refused"
      raise_unless_prepared!(outcome)

      settlement[:commit_item_id] = settle(request, holding)
      outcome
    end

    private

      attr_reader :reservations

      # The intent stores the ownership row's generation, and commit and abort
      # are rebuilt from the intent, so a request built for another generation
      # would settle under a different one than it prepared under.
      def lock_current_generation!(connection, request)
        OperationLock.acquire!(connection, company_id: request.company_id, invoice_id: request.invoice_id)
        raise Timekeeping::BillingFence::OwnershipMoving unless request.generation == TimekeepingOwnership.current.generation
      end

      # After commit, the commit row is delivered inline. After rollback, the
      # failure is recorded once the outermost transaction has ended. A
      # refused prepare is recorded on either end, because a caller may rescue
      # the refusal and commit; Rails fires exactly one of the two callbacks,
      # so it is recorded once.
      def register_settlement_callbacks(connection, request, settlement)
        transaction = connection.current_transaction
        transaction.after_commit do
          record_refusal(request, settlement[:refusal]) if settlement[:refusal]
          deliver(settlement[:commit_item_id]) if settlement[:commit_item_id]
        end
        transaction.after_rollback do
          after_outermost_transaction(connection) do
            record_failure(request)
            record_refusal(request, settlement[:refusal]) if settlement[:refusal]
          end
        end
      end

      def raise_unless_prepared!(outcome)
        route = PREPARE_ROUTES.fetch(outcome.state)
        raise route.new(outcome) if route == OperationErrors::Refused
        raise route unless route == :settle
      end

      # Rails runs after_rollback callbacks when a savepoint rolls back, while
      # the enclosing transaction is still open. The failure write must commit
      # on its own before the abort is delivered, so it waits until no
      # transaction is open, re-registering on each enclosing one; exactly one
      # of the two callbacks fires when that transaction ends.
      def after_outermost_transaction(connection, &block)
        return block.call unless connection.transaction_open?

        enclosing = connection.current_transaction
        enclosing.after_commit { after_outermost_transaction(connection, &block) }
        enclosing.after_rollback { after_outermost_transaction(connection, &block) }
      end

      def write_pending_intent(request)
        InvoiceOperationsRecord.with_connection do |intent_connection|
          intent_connection.transaction do
            intent_connection.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish,
              INSERT INTO invoice_operation_intents
                (company_id, invoice_id, operation_id, state, generation, disposition, desired_entry_ids, created_at)
              VALUES (?, ?, ?, 'pending', ?, ?, ?::bigint[], ?)
            SQL
              request.company_id, request.invoice_id, request.operation_id, request.generation,
              request.disposition, "{#{request.entries.join(',')}}", Time.current]))
          end
        end
      end

      # Runs in the invoice transaction. Raises when the intent is no longer
      # pending: recovery already failed it and wrote its abort, so the
      # invoice change and a commit row must not survive.
      def settle(request, holding)
        moved = pending_intent(request).update_all(state: "committed", finished_at: Time.current)
        raise OperationErrors::IntentNotPending unless moved == 1

        InvoiceEntryHolding.upsert(
          { company_id: request.company_id, invoice_id: request.invoice_id,
            entry_ids: holding.fetch(:entry_ids), disposition: holding.fetch(:disposition) },
          unique_by: %i[company_id invoice_id]
        )
        insert_outbox_item(request, "commit")
      end

      # Runs once the outermost transaction around the save has ended. The
      # advisory lock was released with it, so it is taken again before the
      # guarded update.
      # When the update changes no row the intent was already settled
      # elsewhere and nothing is written. When this write itself fails, the
      # intent stays pending for recovery and the caller still sees the
      # original error.
      def record_failure(request)
        abort_item_id = ApplicationRecord.transaction do
          OperationLock.acquire!(ApplicationRecord.connection, company_id: request.company_id, invoice_id: request.invoice_id)
          moved = pending_intent(request).update_all(state: "failed", finished_at: Time.current)
          insert_outbox_item(request, "abort") if moved == 1
        end
        deliver(abort_item_id) if abort_item_id
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { company_id: request.company_id, operation_id: request.operation_id })
      end

      # Keeps the refusal for the prepare_refusal alert (section 11.3): one
      # row per conflict reason, or one row with no reason when the outcome
      # named none. A backstop for a database fault here: the refusal is
      # already decided, and a lost record must not replace the caller's error.
      def record_refusal(request, outcome)
        reasons = outcome.conflicts.map { |conflict| conflict.fetch(:reason) }.uniq.presence || [nil]
        TimekeepingPrepareRefusal.insert_all!(reasons.map { |reason| { company_id: request.company_id, reason: } })
      rescue StandardError => error
        Rails.logger.warn("prepare refusal not recorded: #{error.class}")
      end

      def pending_intent(request)
        InvoiceOperationIntent.where(
          company_id: request.company_id, invoice_id: request.invoice_id,
          operation_id: request.operation_id, state: "pending"
        )
      end

      def insert_outbox_item(request, kind)
        InvoiceOperationOutboxItem.record!(
          kind:, company_id: request.company_id, invoice_id: request.invoice_id,
          operation_id: request.operation_id, generation: request.generation,
          disposition: request.disposition, desired_entry_ids: request.entries
        )
      end

      # Runs after the invoice transaction has ended. Delivery never raises, so
      # a failure leaves the row undelivered for the worker and the settled
      # save is not reported as failed.
      def deliver(outbox_item_id)
        DeliverInvoiceOperationJob.perform_now(outbox_item_id, reservations:)
      end
  end
end

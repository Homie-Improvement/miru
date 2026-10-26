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
  # inline; a failed delivery is left for the invoice_operations worker.
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

      OperationLock.acquire!(connection, company_id: request.company_id, invoice_id: request.invoice_id)
      generation = write_pending_intent(request)

      settlement = { commit_item_id: nil }
      transaction = connection.current_transaction
      transaction.after_commit { deliver(settlement[:commit_item_id]) if settlement[:commit_item_id] }
      transaction.after_rollback { record_failure(request, generation) }

      outcome = reservations.prepare(request)
      route = PREPARE_ROUTES.fetch(outcome.state)
      raise route.new(outcome) if route == OperationErrors::Refused
      raise route unless route == :settle

      settlement[:commit_item_id] = settle(request, holding, generation)
      outcome
    end

    private

      attr_reader :reservations

      # Returns the ownership generation it stored on the intent.
      def write_pending_intent(request)
        generation = TimekeepingOwnership.current.generation
        InvoiceOperationsRecord.with_connection do |intent_connection|
          intent_connection.transaction do
            intent_connection.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish,
              INSERT INTO invoice_operation_intents
                (company_id, invoice_id, operation_id, state, generation, disposition, desired_entry_ids, created_at)
              VALUES (?, ?, ?, 'pending', ?, ?, ?::bigint[], ?)
            SQL
              request.company_id, request.invoice_id, request.operation_id, generation,
              request.disposition, "{#{request.entries.join(',')}}", Time.current]))
          end
        end
        generation
      end

      # Runs in the invoice transaction. Raises when the intent is no longer
      # pending: recovery already failed it and wrote its abort, so the
      # invoice change and a commit row must not survive.
      def settle(request, holding, generation)
        moved = pending_intent(request).update_all(state: "committed", finished_at: Time.current)
        raise OperationErrors::IntentNotPending unless moved == 1

        InvoiceEntryHolding.upsert(
          { company_id: request.company_id, invoice_id: request.invoice_id,
            entry_ids: holding.fetch(:entry_ids), disposition: holding.fetch(:disposition) },
          unique_by: %i[company_id invoice_id]
        )
        insert_outbox_item(request, "commit", generation)
      end

      # Runs once the invoice transaction has rolled back. The advisory lock
      # was released with it, so it is taken again before the guarded update.
      # When the update changes no row the intent was already settled
      # elsewhere and nothing is written. When this write itself fails, the
      # intent stays pending for recovery and the caller still sees the
      # original error.
      def record_failure(request, generation)
        abort_item_id = ApplicationRecord.transaction do
          OperationLock.acquire!(ApplicationRecord.connection, company_id: request.company_id, invoice_id: request.invoice_id)
          moved = pending_intent(request).update_all(state: "failed", finished_at: Time.current)
          insert_outbox_item(request, "abort", generation) if moved == 1
        end
        deliver(abort_item_id) if abort_item_id
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { company_id: request.company_id, operation_id: request.operation_id })
      end

      def pending_intent(request)
        InvoiceOperationIntent.where(
          company_id: request.company_id, invoice_id: request.invoice_id,
          operation_id: request.operation_id, state: "pending"
        )
      end

      def insert_outbox_item(request, kind, generation)
        InvoiceOperationOutboxItem.record!(
          kind:, company_id: request.company_id, invoice_id: request.invoice_id,
          operation_id: request.operation_id, generation:,
          disposition: request.disposition, desired_entry_ids: request.entries
        )
      end

      # Runs after the invoice transaction has ended, so an error here must not
      # reach the caller: the save is already settled, and the row stays
      # undelivered for the worker.
      def deliver(outbox_item_id)
        DeliverInvoiceOperationJob.perform_now(outbox_item_id, reservations:)
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { outbox_item_id: })
      end
  end
end

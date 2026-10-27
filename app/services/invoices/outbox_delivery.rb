# frozen_string_literal: true

require "yaml"

module Invoices
  # Delivers one commit or abort outbox row to the reservation adapter.
  #
  # The request is rebuilt only from the stored outbox row and its intent,
  # never from the invoice, so a row still delivers after the invoice changed
  # or was never committed. The intent is looked up under the row's own
  # company, so a row can never settle another company's reservation.
  #
  # A row is delivered only when the adapter's answer, read as the
  # operation's remote state, and the intent's current state form a pair the
  # contract's save_reconciliation table settles (Invoices::SaveReconciliation),
  # so an answer alone never settles a row.
  #
  # A stale_generation answer marks the row undeliverable: the operation was
  # prepared under a generation the store no longer accepts, so resending it
  # can never succeed. The row and its intent are kept, delivered_at stays
  # empty, and a warning is logged for operators.
  #
  # The row is locked for the whole delivery and skipped when another
  # deliverer holds it, so inline delivery and the worker never both call the
  # adapter for one row. Every other result, including a failed adapter
  # lookup or a raised error, is counted as an attempt and leaves the row for
  # the next sweep; delivery never raises to its caller, because by the time
  # it runs the invoice change is already committed or rolled back.
  class OutboxDelivery
    STALE_GENERATION_REASON = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/reservations.yml"))
      .dig("errors", "stale_generation", "body", "reason").freeze

    def initialize(adapter_source:)
      @adapter_source = adapter_source
    end

    def deliver(outbox_item_id)
      InvoiceOperationOutboxItem.transaction do
        item = InvoiceOperationOutboxItem.lock("FOR UPDATE SKIP LOCKED").find_by(id: outbox_item_id)
        next if item.nil? || item.delivered_at.present? || item.undeliverable_at.present?

        intent = intent_for(item)
        outcome = settle(item, intent)
        record(item, intent, outcome)
        outcome
      end
    rescue StandardError => error
      # Backstop for a database failure while locking or recording the row:
      # the row stays undelivered for the next sweep, and the caller (inline
      # delivery or the sweep's next row) carries on.
      Rails.error.report(error, handled: true, context: { outbox_item_id: })
      nil
    end

    private

      attr_reader :adapter_source

      def settle(item, intent)
        return if intent.nil?

        request = request_for(item, intent)

        # A savepoint keeps a database error raised by the adapter from
        # aborting the transaction that must still record the attempt.
        InvoiceOperationOutboxItem.transaction(requires_new: true) do
          adapter_source.call.public_send(item.kind, request)
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { outbox_item_id: item.id, company_id: item.company_id })
        nil
      end

      def request_for(item, intent)
        ReservationRequest.new(
          company_id: item.company_id,
          invoice_id: item.invoice_id,
          operation_id: item.operation_id,
          generation: intent.generation,
          disposition: intent.disposition,
          entries: intent.desired_entry_ids
        )
      end

      def intent_for(item)
        scope = InvoiceOperationIntent.where(company_id: item.company_id, operation_id: item.operation_id)
        scope = scope.where(invoice_id: item.invoice_id) if item.invoice_id
        scope.first
      end

      def record(item, intent, outcome)
        case result(intent, outcome)
        when :delivered
          InvoiceOperationOutboxItem.where(id: item.id, delivered_at: nil).update_all(delivered_at: Time.current)
        when :undeliverable
          InvoiceOperationOutboxItem.where(id: item.id, undeliverable_at: nil).update_all(undeliverable_at: Time.current)
          Rails.logger.warn(
            "invoice operation outbox row undeliverable: stale_generation " \
            "outbox_item_id=#{item.id} company_id=#{item.company_id} operation_id=#{item.operation_id} kind=#{item.kind}"
          )
        else
          InvoiceOperationOutboxItem.where(id: item.id).update_all("attempts = attempts + 1")
        end
      end

      def result(intent, outcome)
        return :retry if intent.nil? || outcome.nil?
        return :undeliverable if outcome.state == "retryable" && outcome.reason == STALE_GENERATION_REASON

        settled = !SaveReconciliation.call(remote_state: outcome.state, intent_state: intent.state).fetch("retryable")
        settled ? :delivered : :retry
      end
  end
end

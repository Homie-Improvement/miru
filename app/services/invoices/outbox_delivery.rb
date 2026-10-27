# frozen_string_literal: true

module Invoices
  # Delivers one commit or abort outbox row to the reservation adapter.
  #
  # The request is rebuilt only from the stored outbox row and its intent,
  # never from the invoice, so a row still delivers after the invoice changed
  # or was never committed. The intent is looked up under the row's own
  # company, so a row can never settle another company's reservation.
  #
  # The row is locked for the whole delivery and skipped when another
  # deliverer holds it, so inline delivery and the worker never both call the
  # adapter for one row. Every result that is not settled, including a failed
  # adapter lookup or a raised error, is counted as an attempt and leaves the
  # row for the next sweep; delivery never raises to its caller, because by
  # the time it runs the invoice change is already committed or rolled back.
  class OutboxDelivery
    # The adapter answer that settles each kind of row.
    SETTLED_STATE = { "commit" => "committed", "abort" => "aborted" }.freeze

    def initialize(adapter_source:)
      @adapter_source = adapter_source
    end

    def deliver(outbox_item_id)
      InvoiceOperationOutboxItem.transaction do
        item = InvoiceOperationOutboxItem.lock("FOR UPDATE SKIP LOCKED").find_by(id: outbox_item_id)
        next if item.nil? || item.delivered_at.present? || item.undeliverable_at.present?

        outcome = settle(item)
        record(item, outcome)
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

      def settle(item)
        request = request_for(item)
        return if request.nil?

        # A savepoint keeps a database error raised by the adapter from
        # aborting the transaction that must still record the attempt.
        InvoiceOperationOutboxItem.transaction(requires_new: true) do
          adapter_source.call.public_send(item.kind, request)
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { outbox_item_id: item.id, company_id: item.company_id })
        nil
      end

      def request_for(item)
        intent = intent_for(item)
        return if intent.nil?

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

      def record(item, outcome)
        if outcome&.state == SETTLED_STATE.fetch(item.kind)
          InvoiceOperationOutboxItem.where(id: item.id, delivered_at: nil).update_all(delivered_at: Time.current)
        else
          InvoiceOperationOutboxItem.where(id: item.id).update_all("attempts = attempts + 1")
        end
      end
  end
end

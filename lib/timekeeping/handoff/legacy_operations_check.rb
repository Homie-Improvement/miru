# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The settle and drain integration of a legacy source. The legacy
    # monolith registers no invoice operations and has no entry outbox
    # (docs/architecture/timekeeping-soa.md section 10.5), so there is nothing
    # to resolve, stop or deliver: settling and draining only confirm that no
    # intent is pending and no operation is prepared. A row found unresolved
    # keeps the handoff fenced and resumable.
    #
    # Intents are written through InvoiceOperationsRecord's own connection, so
    # that is the connection this reads them on.
    class LegacyOperationsCheck
      UNRESOLVED_SQL = <<~SQL.squish
        SELECT
          EXISTS (SELECT 1 FROM invoice_operation_intents WHERE state = 'pending')
          OR EXISTS (SELECT 1 FROM invoice_operations WHERE state = 'prepared')
      SQL

      # The legacy reservation adapter (Invoices::LegacyReservations) settles
      # an invoice save in the save's own transaction, so its intents reach
      # 'committed' with no invoice_operations row behind them, and those
      # intents stay in the monolith after the legacy source is retired.
      # Reconciliation requires a committed operation for every committed
      # intent, so each intent the legacy adapter committed is listed as an
      # expected difference instead, keyed by the invoice and operation it
      # names. The legacy adapter served every intent created while
      # legacy_retired_at was null: it is set in the flip transaction, and
      # admission stays closed from step 1 until that flip, so no intent is
      # created between the last legacy write and the retirement.
      #
      # A correction explains any "state" difference on its intent, so one is
      # listed only for an intent committed both at the checkpoint and now:
      # listing from either side alone would explain a state change made
      # after the checkpoint, which reconcile must report.
      #
      # source_intents: the invoice_operation_intents rows frozen at the checkpoint.
      # intents: the same table as read for reconciliation.
      # legacy_retired_at: the ownership row's value, nil while legacy.
      # Returns { company_id => [Reconciliation::Correction] }.
      def self.listed_receipts(source_intents:, intents:, legacy_retired_at:)
        # An intent is unique per company, invoice and operation, so the
        # company is part of the match: another company's committed intent
        # with the same invoice and operation ids must not vouch for this one.
        company_receipt_key = ->(intent) { [intent["company_id"], *Reconciliation::RECEIPT_LINK_KEY.call(intent)] }
        committed_at_checkpoint = source_intents
          .select { |intent| intent["state"] == "committed" }
          .to_set(&company_receipt_key)
        intents
          .select { |intent| intent["state"] == "committed" }
          .select { |intent| committed_at_checkpoint.include?(company_receipt_key.call(intent)) }
          .select { |intent| legacy_retired_at.nil? || intent["created_at"] < legacy_retired_at }
          .group_by { |intent| intent["company_id"] }
          .transform_values do |committed|
            committed.map do |intent|
              Reconciliation::Correction.new(
                check: :operation_receipts, row_key: Reconciliation::RECEIPT_LINK_KEY.call(intent), field: "state"
              )
            end
          end
      end

      def initialize(connection: InvoiceOperationsRecord.connection)
        @connection = connection
      end

      def settle!(generation:) = nil
      def stop_applying! = nil
      def drain!(through:) = nil

      def settled?
        !unresolved?
      end

      def drained?(through:)
        !unresolved?
      end

      private

        def unresolved?
          ActiveRecord::Type::Boolean.new.cast(@connection.select_value(UNRESOLVED_SQL))
        end
    end
  end
end

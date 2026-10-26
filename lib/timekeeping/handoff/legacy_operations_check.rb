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

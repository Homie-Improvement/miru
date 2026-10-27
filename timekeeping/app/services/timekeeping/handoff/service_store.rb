# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The checkpoint store over Timekeeping's own tables. Export, load and the
    # entry id sequence are TableStore's; this class names Timekeeping's
    # tables, reads the outbox position from outbox_snapshots, which it never
    # writes, and refuses a load while entry writes are admitted.
    class ServiceStore < TableStore
      # Timekeeping keeps entry audits and idempotency receipts under its own
      # table names; their columns equal the checkpoint's.
      TABLES = {
        "entries" => "entries",
        "reservations" => "reservations",
        "invoice_operations" => "invoice_operations",
        "entry_audits" => "audit_events",
        "idempotency_records" => "idempotency_receipts",
        "service_idempotency_receipts" => "service_idempotency_receipts"
      }.freeze

      def initialize(connection:)
        super(connection:, tables: TABLES)
      end

      def highest_outbox_position
        connection.select_value("SELECT COALESCE(MAX(outbox_position), 0) FROM outbox_snapshots").to_i
      end

      private

        # A load deletes every row the checkpoint lacks, so an entry written
        # after the export would be lost. The load therefore runs only while
        # admission is fenced.
        def check_load_allowed!
          FenceCheck.require_fenced!(connection, "load a checkpoint")
        end
    end
  end
end

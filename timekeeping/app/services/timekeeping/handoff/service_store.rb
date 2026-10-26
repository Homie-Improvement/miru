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
        "idempotency_records" => "idempotency_receipts"
      }.freeze

      def initialize(connection:)
        super(connection:, tables: TABLES)
      end

      # Refuses the whole checkpoint, before anything is deleted, when an entry
      # holds a value the projection would refuse: a later write would
      # republish the stored row and hold back every snapshot after it. The
      # message names entries and fields only, because row values can be private.
      def load_checkpoint(checkpoint)
        invalid = CheckpointEntryValues.invalid_entries(checkpoint.rows.fetch("entries", []))
        if invalid.any?
          raise Checkpoint::ShapeError,
                "checkpoint entries: invalid values in #{invalid.map { |entry| describe_invalid_entry(entry) }.join('; ')}"
        end

        super
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

        # An identifier is named only when it passed its own rule: an invalid
        # id or company_id can hold any text, including private text.
        def describe_invalid_entry(entry)
          identifiers = { "company_id" => entry[:company_id], "id" => entry[:id] }
                        .map { |field, value| entry[:fields].include?(field) ? "#{field} invalid" : "#{field} #{value}" }
          "#{identifiers.join(' ')} (#{entry[:fields].join(', ')})"
        end
    end
  end
end

# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The copy of a non-legacy checkpoint a handoff loads into the incoming
    # owner. Timekeeping never keeps its stored entries.locked column current:
    # an entry is locked exactly when it has a reservation, and its outbox
    # publishes that value to the projection. Loading the stored column as it
    # is would leave the incoming owner and the drained projection disagreeing
    # on every entry reserved while Timekeeping owned it. Each entry in the
    # copy therefore carries locked as its reservations say.
    #
    # Pure: it reads a checkpoint and builds new ones.
    module ReservationLocks
      module_function

      def build(source)
        reserved = reserved_keys(source)
        entries = source.rows.fetch("entries").map do |row|
          locked = reserved.include?(entry_key(row))
          row["locked"] == locked ? row : row.merge("locked" => locked)
        end
        Checkpoint.build(tables: source.rows.merge("entries" => entries))
      end

      # The locked values the copy changed, by company, for reconciliation to
      # accept in its entries check.
      #
      # Returns { company_id => [Reconciliation::Correction] }.
      def listed_corrections(source:, loaded:)
        source_locked = source.rows.fetch("entries").to_h { |row| [entry_key(row), row["locked"]] }
        changed = loaded.rows.fetch("entries").reject { |row| source_locked[entry_key(row)] == row["locked"] }

        changed.group_by { |row| row["company_id"] }.transform_values do |rows|
          rows.map { |row| Reconciliation::Correction.new(check: :entries, row_key: [row["id"]], field: "locked") }
        end
      end

      def reserved_keys(checkpoint)
        checkpoint.rows.fetch("reservations").to_set { |row| [row["company_id"], row["entry_id"]] }
      end

      def entry_key(row)
        [row["company_id"], row["id"]]
      end
      private_class_method :reserved_keys, :entry_key
    end
  end
end

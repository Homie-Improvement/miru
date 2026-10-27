# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The value check for the entries rows of a checkpoint being loaded.
    # WriteSteps.write_outbox republishes stored rows without checking them, so
    # a loaded value the projection refuses would hold back every later
    # snapshot. The rows are the decoded values the load inserts.
    #
    # Pure: it reads plain hashes and touches no database.
    module CheckpointEntryValues
      # Every SnapshotValues rule except locked: entries.locked is nullable and
      # OutboxFields.row replaces it with the reservation flag, so the stored
      # value never reaches a snapshot. A checkpoint carries version as stored
      # rather than assigned by a writer, so it gets the projection's rule for
      # it, a positive Integer, the same rule as id.
      RULES = SnapshotValues::RULES.except("locked").merge("version" => SnapshotValues::RULES.fetch("id")).freeze

      module_function

      # Returns [{ company_id:, id:, fields: [field names] }], one item per row
      # with an invalid value, in row order; [] when every row is valid.
      def invalid_entries(rows)
        rows.filter_map do |row|
          fields = SnapshotValues.invalid_fields(row, rules: RULES)
          { company_id: row["company_id"], id: row["id"], fields: } if fields.any?
        end
      end
    end
  end
end

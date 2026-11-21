# frozen_string_literal: true

# Drops the keys from billing rows to timesheet entries, and from entries to
# agents, so the ownership handoff can delete an agent or move entry rows while
# the projection still names them (docs/architecture/timekeeping-soa.md
# sections 3.3 and 10.2, step S1b). Model validations already refuse these
# references; the keys to projects and users stay.
#
# Ship this only in a release after every web and worker process runs those
# validations, never in the same release that added them.
#
# The key list and the rollback check are defined here, not read from an
# earlier migration, so this recorded migration keeps doing what it did when
# it ran.
class DropTimesheetEntryForeignKeysForCutover < ActiveRecord::Migration[8.1]
  # Validating a restored key in its own step, outside one long transaction,
  # follows the repository's pattern for adding keys to existing tables.
  disable_ddl_transaction!

  DROPPED_KEYS = [
    { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
    { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
    { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
  ].map(&:freeze).freeze

  class DanglingReferencesError < StandardError; end

  # Without a transaction a failed run can leave some keys removed and the
  # version unrecorded; if_exists lets the next run finish the drop.
  def up
    DROPPED_KEYS.each do |key|
      remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
  end

  def down
    # A row written without the keys can point at a missing row, and restoring
    # the key would then fail part-way. Stop first and change no data instead.
    dangling = dangling_reference_counts
    if dangling.any?
      details = dangling.map { |reference, count| "#{reference}: #{count}" }.join(", ")
      raise DanglingReferencesError, "Cannot restore foreign keys, rows point at missing records (#{details})"
    end

    DROPPED_KEYS.each do |key|
      add_foreign_key key[:from_table], key[:to_table], column: key[:column], validate: false, if_not_exists: true
      validate_foreign_key key[:from_table], key[:to_table], column: key[:column]
    end
  end

  private

    def dangling_reference_counts
      DROPPED_KEYS.each_with_object({}) do |key, counts|
        count = select_value(<<~SQL.squish).to_i
          SELECT count(*) FROM #{key[:from_table]} source
          WHERE source.#{key[:column]} IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM #{key[:to_table]} target WHERE target.id = source.#{key[:column]})
        SQL
        counts["#{key[:from_table]}.#{key[:column]}"] = count if count.positive?
      end
    end
end

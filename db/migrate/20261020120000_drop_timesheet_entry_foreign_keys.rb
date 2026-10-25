# frozen_string_literal: true

# Drops the database references to timesheet entries from billing rows, and from
# entries to agents, so a later ownership handoff can move entry rows without
# these keys blocking it. Model validations now refuse the same missing
# references: InvoiceLineItem and InvoiceLineItemTimeEntry check that their
# entry exists, and TimesheetEntry checks that its agent exists.
class DropTimesheetEntryForeignKeys < ActiveRecord::Migration[8.1]
  # Validating a restored key in its own step, outside one long transaction,
  # follows the repository's pattern for adding keys to existing tables.
  disable_ddl_transaction!

  DROPPED_KEYS = [
    { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
    { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
    { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
  ].freeze

  class DanglingReferencesError < StandardError; end

  def up
    DROPPED_KEYS.each do |key|
      remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
  end

  def down
    # A row written without the keys could point at a missing row. Restoring the
    # key would then fail part-way; stop first and change no data instead.
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

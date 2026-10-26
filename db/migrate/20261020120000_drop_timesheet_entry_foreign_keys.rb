# frozen_string_literal: true

# The keys from billing rows to timesheet entries, and from entries to agents,
# must go before a later ownership handoff can move entry rows. Model
# validations take over their refusal: InvoiceLineItem and
# InvoiceLineItemTimeEntry check that their entry exists, and TimesheetEntry
# checks that its agent exists.
#
# This migration keeps the keys. A rolling deploy migrates while older web and
# worker processes, which lack those validations, still write, so the keys are
# dropped only in a release that follows one already running the validations.
# Step S1 in docs/architecture/timekeeping-soa.md section 10.2 records that order.
#
# Databases that ran an earlier version of this migration have already lost the
# keys. Its down restores them, and refuses without changing data when a row
# points at a missing record.
class DropTimesheetEntryForeignKeys < ActiveRecord::Migration[8.1]
  # Validating a restored key in its own step, outside one long transaction,
  # follows the repository's pattern for adding keys to existing tables.
  disable_ddl_transaction!

  DROPPED_KEYS = [
    { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
    { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
    { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
  ].map(&:freeze).freeze

  class DanglingReferencesError < StandardError; end

  # Removes nothing, and adds back nothing: re-adding a key here would fail on
  # any row written while it was absent.
  def up; end

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

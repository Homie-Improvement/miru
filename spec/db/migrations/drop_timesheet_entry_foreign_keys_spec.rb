# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261020120000_drop_timesheet_entry_foreign_keys")

# Runs the migration's down and up inside the example's transaction, so every
# key it restores or drops is rolled back after the example.
RSpec.describe DropTimesheetEntryForeignKeys do
  let(:connection) { ActiveRecord::Base.connection }

  def run_migration(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def foreign_key_validated?(from_table, to_table)
    connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE contype = 'f'
        AND conrelid = #{connection.quote(from_table)}::regclass
        AND confrelid = #{connection.quote(to_table)}::regclass
    SQL
  end

  it "stops the rollback before any change when a line item points at a missing entry" do
    line_item = create(:invoice_line_item)
    missing_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000
    connection.execute("UPDATE invoice_line_items SET timesheet_entry_id = #{missing_entry_id} WHERE id = #{line_item.id}")

    expect { run_migration(:down) }
      .to raise_error(described_class::DanglingReferencesError, /invoice_line_items\.timesheet_entry_id: 1/)
    expect(line_item.reload.timesheet_entry_id).to eq(missing_entry_id)
    expect(connection.foreign_key_exists?(:timesheet_entries, :agents)).to be(false)
  end

  it "restores the three keys, validated, on rollback" do
    run_migration(:down)

    expect(connection.foreign_key_exists?(:invoice_line_item_time_entries, :timesheet_entries)).to be(true)
    expect(connection.foreign_key_exists?(:invoice_line_items, :timesheet_entries)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :agents)).to be(true)
    expect(foreign_key_validated?("timesheet_entries", "agents")).to be(true)
  end

  it "drops the three keys and keeps the entry keys to projects and users" do
    run_migration(:down)
    run_migration(:up)

    expect(connection.foreign_key_exists?(:invoice_line_item_time_entries, :timesheet_entries)).to be(false)
    expect(connection.foreign_key_exists?(:invoice_line_items, :timesheet_entries)).to be(false)
    expect(connection.foreign_key_exists?(:timesheet_entries, :agents)).to be(false)
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end
end

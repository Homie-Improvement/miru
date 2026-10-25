# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261025120000_prepare_monolith_for_timekeeping")
require Rails.root.join("db/migrate/20261025120100_backfill_timesheet_entry_company_ids")

# Runs the migration's down and up inside the example's transaction, so every
# column and table it drops or creates is rolled back after the example.
RSpec.describe PrepareMonolithForTimekeeping do
  let(:connection) { ActiveRecord::Base.connection }

  new_tables = %w[
    timekeeping_ownership invoice_operation_intents entries reservations invoice_operations
    entry_audits idempotency_records entry_outbox_items
  ].freeze

  def run_migration(direction, migration_class = described_class)
    ActiveRecord::Migration.suppress_messages { migration_class.new.migrate(direction) }
    TimesheetEntry.reset_column_information
  end

  def rows(sql)
    connection.select_all(sql).to_a
  end

  def entry_rows_without_new_columns
    rows("SELECT * FROM timesheet_entries ORDER BY id").map { |row| row.except("company_id", "version") }
  end

  def billing_rows
    {
      invoices: rows("SELECT * FROM invoices ORDER BY id"),
      invoice_taxes: rows("SELECT * FROM invoice_taxes ORDER BY id"),
      line_items: rows("SELECT * FROM invoice_line_items ORDER BY id"),
      links: rows("SELECT * FROM invoice_line_item_time_entries ORDER BY id")
    }
  end

  after { TimesheetEntry.reset_column_information }

  it "fills company_id in the backfill migration and changes no other entry value or billing row" do
    discarded_entry = create(:timesheet_entry)
    discarded_entry.discard!
    entry_on_discarded_project = create(:timesheet_entry)
    entry_on_discarded_project.project.discard!
    line_item = create(:invoice_line_item)
    create(:invoice_line_item_time_entry, invoice_line_item: line_item)
    create(:invoice_tax, invoice: line_item.invoice)
    line_item.invoice.update_columns(discount: 5, tax: 12.5)
    run_migration(:down)
    entries_before = entry_rows_without_new_columns
    billing_before = billing_rows
    audit_count = Audited::Audit.count

    run_migration(:up)
    run_migration(:up, BackfillTimesheetEntryCompanyIds)

    expect(entry_rows_without_new_columns).to eq(entries_before)
    expect(billing_rows).to eq(billing_before)
    expect(Audited::Audit.count).to eq(audit_count)
    mismatched = connection.select_value(<<~SQL.squish)
      SELECT count(*) FROM timesheet_entries
      INNER JOIN projects ON projects.id = timesheet_entries.project_id
      INNER JOIN clients ON clients.id = projects.client_id
      WHERE timesheet_entries.company_id IS DISTINCT FROM clients.company_id
    SQL
    expect(mismatched).to eq(0)
    expect(connection.select_values("SELECT DISTINCT version FROM timesheet_entries")).to eq([0])
  end

  it "removes the entry columns and every new table on rollback" do
    run_migration(:down)

    expect(connection.column_exists?(:timesheet_entries, :company_id)).to be(false)
    expect(connection.column_exists?(:timesheet_entries, :version)).to be(false)
    expect(new_tables.select { |table| connection.table_exists?(table) }).to eq([])
  end

  it "inserts exactly one ownership row, generation 1 owned by the monolith with no handoff step" do
    run_migration(:down)
    run_migration(:up)

    expect(rows("SELECT generation, owner, handoff_step FROM timekeeping_ownership"))
      .to eq([{ "generation" => 1, "owner" => "monolith", "handoff_step" => nil }])
  end

  it "leaves every new table except the ownership record empty" do
    run_migration(:down)
    run_migration(:up)

    counts = (new_tables - ["timekeeping_ownership"]).index_with do |table|
      connection.select_value("SELECT count(*) FROM #{table}")
    end
    expect(counts.values.uniq).to eq([0])
  end
end

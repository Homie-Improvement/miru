# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261026130000_add_invoice_reservation_ledger")

# Runs only this migration's down and up inside the example's transaction, so
# the schema is restored after the example even when an assertion fails.
RSpec.describe AddInvoiceReservationLedger do
  let(:connection) { ActiveRecord::Base.connection }

  def run_ledger_migration(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    InvoiceOperationIntent.reset_column_information
  end

  def ledger_check_constraint_names(table)
    connection.check_constraints(table).map(&:name)
  end

  def ledger_unique_index_names(table)
    connection.indexes(table).filter_map { |index| index.name if index.unique }
  end

  after { InvoiceOperationIntent.reset_column_information }

  it "removes the intent request columns and both new tables on rollback and keeps the older intent schema" do
    run_ledger_migration(:down)

    expect(connection.column_exists?(:invoice_operation_intents, :desired_entry_ids)).to be(false)
    expect(connection.column_exists?(:invoice_operation_intents, :disposition)).to be(false)
    expect(connection.table_exists?(:invoice_entry_holdings)).to be(false)
    expect(connection.table_exists?(:invoice_operation_outbox_items)).to be(false)
    expect(connection.columns(:invoice_operation_intents).map(&:name))
      .to match_array(%w[id company_id invoice_id operation_id state generation created_at finished_at])
    expect(ledger_unique_index_names(:invoice_operation_intents))
      .to eq(["index_invoice_operation_intents_on_company_invoice_operation"])
    expect(ledger_check_constraint_names(:invoice_operation_intents)).to eq(["invoice_operation_intents_state_check"])
  end

  it "restores the named unique indexes and the three check constraints on up" do
    run_ledger_migration(:down)
    run_ledger_migration(:up)

    expect(ledger_unique_index_names(:invoice_entry_holdings)).to eq(["index_invoice_entry_holdings_on_company_invoice"])
    expect(ledger_unique_index_names(:invoice_operation_outbox_items))
      .to eq(["index_invoice_operation_outbox_items_on_company_operation_kind"])
    expect(ledger_check_constraint_names(:invoice_operation_intents)).to include("invoice_operation_intents_disposition_check")
    expect(ledger_check_constraint_names(:invoice_entry_holdings)).to eq(["invoice_entry_holdings_disposition_check"])
    expect(ledger_check_constraint_names(:invoice_operation_outbox_items)).to eq(["invoice_operation_outbox_items_kind_check"])
  end

  it "gives the holdings no foreign key, so a holding outlives its invoice" do
    expect(connection.foreign_keys(:invoice_entry_holdings)).to eq([])
  end
end

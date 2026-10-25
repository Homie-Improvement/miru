# frozen_string_literal: true

require "rails_helper"

# The prepared monolith's tables and the invoice operation ledger belong to
# one company per row, so each needs a NOT NULL company_id. The ownership
# record is the one global table and is not listed here.
RSpec.describe "Timekeeping prepared tables" do
  tenant_tables = %w[
    invoice_operation_intents entries reservations invoice_operations
    entry_audits idempotency_records entry_outbox_items
  ].freeze

  let(:connection) { ActiveRecord::Base.connection }

  def company_id_column(table)
    connection.columns(table).find { |column| column.name == "company_id" }
  end

  it "gives every tenant table a NOT NULL company_id" do
    without_required_company = tenant_tables.reject do |table|
      column = company_id_column(table)
      column && !column.null
    end

    expect(without_required_company).to eq([])
  end

  it "starts every tenant table empty" do
    counts = tenant_tables.index_with { |table| connection.select_value("SELECT count(*) FROM #{table}") }

    expect(counts.values.uniq).to eq([0])
  end

  it "gives the prepared entries the snapshot entry_fields" do
    contract = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_snapshots.yml"))

    expect(connection.columns(:entries).map(&:name)).to match_array(contract.fetch("entry_fields"))
  end

  it "refuses a reservation that points at another company's entry" do
    entry_id = connection.select_value(<<~SQL.squish)
      INSERT INTO entries (company_id, project_id, user_id, work_date, duration, bill_status, created_at, updated_at)
      VALUES (1, 1, 1, CURRENT_DATE, 60, 'unbilled', now(), now()) RETURNING id
    SQL

    expect {
      connection.execute(<<~SQL.squish)
        INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at)
        VALUES (2, #{entry_id}, 1, 'committed', 'active', gen_random_uuid(), now())
      SQL
    }.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end

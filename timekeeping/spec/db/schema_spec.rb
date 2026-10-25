# frozen_string_literal: true

require "rails_helper"

# Every table carries a non-null company_id, so every query can start with
# WHERE company_id = :company_id. The tables are read from the live database,
# so a table a later migration adds is checked without editing this spec.
RSpec.describe "Timekeeping database schema" do
  rails_tables = %w[schema_migrations ar_internal_metadata].freeze

  def tenant_tables(connection, skipped)
    connection.tables - skipped
  end

  def tables_without_required_company_id(connection, skipped)
    tenant_tables(connection, skipped).reject do |table|
      column = connection.columns(table).find { |candidate| candidate.name == "company_id" }
      column && !column.null
    end
  end

  let(:connection) { ActiveRecord::Base.connection }

  it "walks the entries and reservations tables" do
    expect(tenant_tables(connection, rails_tables)).to include("entries", "reservations")
  end

  it "gives every table a NOT NULL company_id" do
    expect(tables_without_required_company_id(connection, rails_tables)).to eq([])
  end

  it "reports a table that has no company_id" do
    # Created inside the example's transaction, so it is rolled back after.
    connection.create_table(:schema_spec_untenanted_rows) { |t| t.string :name }
    connection.create_table(:schema_spec_nullable_tenant_rows) { |t| t.bigint :company_id }

    expect(tables_without_required_company_id(connection, rails_tables))
      .to contain_exactly("schema_spec_untenanted_rows", "schema_spec_nullable_tenant_rows")
  end

  it "gives entries exactly the snapshot entry_fields" do
    contract = YAML.safe_load_file(Rails.root.join("../contracts/timekeeping/entry_snapshots.yml"))

    expect(connection.columns(:entries).map(&:name)).to match_array(contract.fetch("entry_fields"))
  end

  it "stores version as a NOT NULL integer" do
    version = connection.columns(:entries).find { |column| column.name == "version" }

    expect([version.type, version.null, version.default]).to eq([:integer, false, "1"])
  end

  it "stores duration as a float" do
    duration = connection.columns(:entries).find { |column| column.name == "duration" }

    expect(duration.type).to eq(:float)
  end
end

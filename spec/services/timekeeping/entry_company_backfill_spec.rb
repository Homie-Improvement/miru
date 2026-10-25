# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::EntryCompanyBackfill do
  let(:connection) { ActiveRecord::Base.connection }

  def stored_company_id(entry)
    connection.select_value("SELECT company_id FROM timesheet_entries WHERE id = #{entry.id}")
  end

  it "sets a missing or wrong company_id to the project's client's company and reports the rows it changed" do
    missing = create(:timesheet_entry)
    wrong = create(:timesheet_entry)
    correct = create(:timesheet_entry)
    other_company = create(:company)
    connection.execute("UPDATE timesheet_entries SET company_id = NULL WHERE id = #{missing.id}")
    connection.execute("UPDATE timesheet_entries SET company_id = #{other_company.id} WHERE id = #{wrong.id}")

    expect(described_class.call(connection)).to eq(2)
    expect(stored_company_id(missing)).to eq(missing.project.client.company_id)
    expect(stored_company_id(wrong)).to eq(wrong.project.client.company_id)
    expect(stored_company_id(correct)).to eq(correct.project.client.company_id)
  end

  it "fixes rows in every id range when the table spans several batches" do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    entries = create_list(:timesheet_entry, 3)
    connection.execute("UPDATE timesheet_entries SET company_id = NULL")

    expect(described_class.call(connection)).to eq(3)
    expect(entries.map { |entry| stored_company_id(entry) }).to eq(entries.map { |entry| entry.project.client.company_id })
  end

  it "changes nothing when run again" do
    create(:timesheet_entry)
    connection.execute("UPDATE timesheet_entries SET company_id = NULL")
    described_class.call(connection)

    expect(described_class.call(connection)).to eq(0)
  end

  it "covers discarded entries and entries of discarded projects" do
    discarded_entry = create(:timesheet_entry)
    discarded_entry.discard!
    entry_on_discarded_project = create(:timesheet_entry)
    entry_on_discarded_project.project.discard!
    connection.execute("UPDATE timesheet_entries SET company_id = NULL")

    described_class.call(connection)

    expect(stored_company_id(discarded_entry)).to eq(discarded_entry.project.client.company_id)
    expect(stored_company_id(entry_on_discarded_project)).to eq(entry_on_discarded_project.project.client.company_id)
  end

  it "writes no other column and no audit row" do
    entry = create(:timesheet_entry)
    connection.execute("UPDATE timesheet_entries SET company_id = NULL, updated_at = '2025-01-01 00:00:00' WHERE id = #{entry.id}")
    columns_before = connection.select_one("SELECT * FROM timesheet_entries WHERE id = #{entry.id}").except("company_id")
    audit_count = Audited::Audit.count

    described_class.call(connection)

    expect(connection.select_one("SELECT * FROM timesheet_entries WHERE id = #{entry.id}").except("company_id"))
      .to eq(columns_before)
    expect(Audited::Audit.count).to eq(audit_count)
  end
end

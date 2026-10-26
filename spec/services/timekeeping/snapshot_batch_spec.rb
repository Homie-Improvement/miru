# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::SnapshotBatch do
  def batch_spec_entry(**fields)
    TimekeepingContract.load(:entry_snapshots).fetch("entry_fields").index_with(nil).merge(
      "id" => 11, "company_id" => 3, "version" => 2, "project_id" => 5, "user_id" => 7,
      "work_date" => "2026-03-02", "duration" => 90.0, "note" => "Review", "bill_status" => "unbilled",
      "review_status" => "approved", "locked" => false, "source" => "cli", "source_metadata" => { "tool" => "codex" },
      "proof_metadata" => {}, "created_at" => "2026-03-02T09:00:00Z", "updated_at" => "2026-03-02T10:00:00+01:00"
    ).merge(fields.transform_keys(&:to_s))
  end

  def batch_spec_batch(*entries, positions: (1..entries.size).to_a)
    { "schema_version" => 1,
      "snapshots" => entries.zip(positions).map { |entry, position| { "generation" => 1, "outbox_position" => position, "entry" => entry } } }
  end

  it "maps a snapshot to timesheet_entries column values" do
    item = described_class.parse(batch_spec_batch(batch_spec_entry)).sole

    expect([item.generation, item.outbox_position, item.entry_id, item.company_id, item.project_id]).to eq([1, 1, 11, 3, 5])
    expect(item.row).to include(
      "bill_status" => TimesheetEntry.bill_statuses.fetch("unbilled"),
      "review_status" => TimesheetEntry.review_statuses.fetch("approved"),
      "duration" => 90.0, "source_metadata" => '{"tool":"codex"}', "work_date" => "2026-03-02",
      "updated_at" => "2026-03-02 09:00:00.000000", "discarded_at" => nil
    )
    expect(item.row.keys).to match_array(TimekeepingContract.load(:entry_snapshots).fetch("entry_fields"))
  end

  it "orders items by outbox_position" do
    items = described_class.parse(batch_spec_batch(batch_spec_entry(version: 3), batch_spec_entry(version: 2), positions: [9, 4]))

    expect(items.map(&:outbox_position)).to eq([4, 9])
  end

  it "accepts an empty batch" do
    expect(described_class.parse(batch_spec_batch)).to eq([])
  end

  it "refuses keys outside the contract and missing keys at every level" do
    entry = batch_spec_entry

    expect(described_class.parse(batch_spec_batch(entry).merge("extra" => 1))).to be_nil
    expect(described_class.parse(batch_spec_batch(entry).except("schema_version"))).to be_nil
    expect(described_class.parse(batch_spec_batch(entry.merge("hours" => 1)))).to be_nil
    expect(described_class.parse(batch_spec_batch(entry.except("note")))).to be_nil
    item = batch_spec_batch(entry)["snapshots"].first.merge("company_id" => 3)
    expect(described_class.parse("schema_version" => 1, "snapshots" => [item])).to be_nil
  end

  it "refuses wrong types and unknown enum values" do
    [
      { id: "11" }, { company_id: nil }, { version: 0 }, { duration: "90" }, { duration: -1.0 },
      { bill_status: "paid" }, { review_status: 1 }, { locked: nil }, { source: "fax" },
      { source_metadata: "{}" }, { work_date: "2026-02-30" }, { created_at: "yesterday" }, { agent_id: 1.5 }
    ].each do |fields|
      expect([fields, described_class.parse(batch_spec_batch(batch_spec_entry(**fields)))]).to eq([fields, nil])
    end
  end

  it "refuses a wrong schema version, a non-integer generation and a non-list of snapshots" do
    expect(described_class.parse(batch_spec_batch(batch_spec_entry).merge("schema_version" => 2))).to be_nil
    expect(described_class.parse("schema_version" => 1, "snapshots" => "none")).to be_nil
    item = batch_spec_batch(batch_spec_entry)["snapshots"].first.merge("generation" => "1")
    expect(described_class.parse("schema_version" => 1, "snapshots" => [item])).to be_nil
    expect(described_class.parse(nil)).to be_nil
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  let(:checkpoint) { Timekeeping::Handoff::Checkpoint }

  def legacy_load_entry(id:, version:)
    at = Time.utc(2026, 3, 2, 9)
    checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => 1, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def legacy_load_checkpoint(entries)
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  def planned_versions(planned)
    planned.rows.fetch("entries").to_h { |row| [row["id"], row["version"]] }
  end

  it "raises an uncorrected version-0 legacy entry to version 1, the lowest version Timekeeping loads" do
    source = legacy_load_checkpoint([legacy_load_entry(id: 7, version: 0), legacy_load_entry(id: 8, version: 4)])

    planned = described_class.build(source:, corrections: [], stored: nil)

    expect(planned_versions(planned)).to eq(7 => 1, 8 => 4)
  end

  it "keeps a higher version Timekeeping already stores" do
    source = legacy_load_checkpoint([legacy_load_entry(id: 7, version: 0)])
    stored = legacy_load_checkpoint([legacy_load_entry(id: 7, version: 3)])

    planned = described_class.build(source:, corrections: [], stored:)

    expect(planned_versions(planned)).to eq(7 => 3)
  end

  it "lists the raise from version 0 as a version correction under the entry's company" do
    source = legacy_load_checkpoint([legacy_load_entry(id: 7, version: 0)])
    planned = described_class.build(source:, corrections: [], stored: nil)

    listed = described_class.listed_corrections(source:, loaded: planned, corrections: [])

    expect(listed.fetch(1).map { |correction| [correction.check, correction.field] })
      .to contain_exactly([:entries, "version"], [:projection, "version"])
  end
end

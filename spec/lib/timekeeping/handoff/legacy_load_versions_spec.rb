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

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions, "raised snapshots and lock values" do
  # Microsecond timestamps, because the live rollback compares entry times to the microsecond.
  def raised_load_entry(id:, version:, company_id: 1, locked: false)
    at = Time.utc(2026, 3, 2, 9, 15, 30, 123_456)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def raised_load_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  def raised_load_correction(row)
    {
      "company_id" => row["company_id"], "entry_id" => row["id"], "generation" => 2, "captured_at" => Time.utc(2026, 10, 1),
      "snapshot" => row.merge("locked" => true, "version" => Timekeeping::ReservationDerivation::CORRECTION_VERSION)
    }
  end

  def raised_load_listing(corrections)
    corrections.map { |correction| [correction.check, correction.row_key, correction.field] }
  end

  it "raised snapshots can share the correction write because the lowest loadable version equals the correction version" do
    expect(described_class::LOWEST_LOADABLE_VERSION).to eq(Timekeeping::ReservationDerivation::CORRECTION_VERSION)
  end

  # A corrected entry keeps its correction snapshot; Timekeeping refuses a
  # snapshot list naming an entry twice.
  it "raised_snapshots gives one snapshot per raised uncorrected entry, equal to the loaded row without version, and none for unraised or corrected entries" do
    raised = raised_load_entry(id: 7, version: 0)
    unraised = raised_load_entry(id: 8, version: 4)
    corrected = raised_load_entry(id: 9, version: 0)
    corrections = [raised_load_correction(corrected)]
    source = raised_load_checkpoint([raised, unraised, corrected])
    loaded = described_class.build(source:, corrections:, stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections:)

    expect(snapshots.size).to eq(1)
    expect(snapshots.first).to eq(raised.except("version"))
    expect(snapshots.first.fetch("created_at")).to eq(Time.utc(2026, 3, 2, 9, 15, 30, 123_456))
    expect(snapshots.first.fetch("updated_at")).to eq(Time.utc(2026, 3, 2, 9, 15, 30, 123_456))
  end

  # A snapshot accepts only true or false for locked, while a legacy row may
  # hold nil; an uncorrected entry has no reservation, so its loaded and
  # relayed lock is false.
  it "raised_snapshots gives a null-lock version-0 legacy entry one snapshot with its own timestamps, a false lock and no version" do
    null_lock = raised_load_entry(id: 7, version: 0, locked: nil)
    other_company = raised_load_entry(id: 9, version: 0, company_id: 2)
    unraised = raised_load_entry(id: 8, version: 4)
    source = raised_load_checkpoint([null_lock, unraised, other_company])
    loaded = described_class.build(source:, corrections: [], stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    expect(snapshots.size).to eq(2)
    expect(snapshots).to all(satisfy { |snapshot| !snapshot.key?("version") })
    by_id = snapshots.index_by { |snapshot| snapshot["id"] }
    expect(by_id.keys).to contain_exactly(7, 9)
    expect(by_id.fetch(7)).to eq(null_lock.except("version").merge("locked" => false))
    expect(by_id.fetch(9)["company_id"]).to eq(2)
    loaded_null_lock = loaded.rows.fetch("entries").find { |row| row["id"] == 7 }
    expect(loaded_null_lock["locked"]).to be(false)
    expect(loaded_null_lock["version"]).to eq(1)
  end

  # The projection applies a snapshot only where its company matches.
  it "raised snapshots for two companies with identical entry data each keep their own company and exact timestamps, and an unraised entry gets none" do
    source = raised_load_checkpoint([
      raised_load_entry(id: 7, version: 0, company_id: 1),
      raised_load_entry(id: 8, version: 0, company_id: 2),
      raised_load_entry(id: 9, version: 4, company_id: 2)
    ])

    loaded = described_class.build(source:, corrections: [], stored: nil)
    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    expect(snapshots.to_h { |snapshot| [snapshot["id"], snapshot["company_id"]] }).to eq(7 => 1, 8 => 2)
    expect(snapshots.pluck("created_at").uniq).to eq([Time.utc(2026, 3, 2, 9, 15, 30, 123_456)])
    expect(snapshots.pluck("updated_at").uniq).to eq([Time.utc(2026, 3, 2, 9, 15, 30, 123_456)])
    expect(snapshots).to all(satisfy { |snapshot| !snapshot.key?("version") })
  end

  # A resume reads the versions Timekeeping already stores from the first
  # attempt; the raised set must still come from the legacy source, or the
  # resumed write would drop entries and leave their projection at version 0.
  it "a resumed cutover that finds its raised versions already stored derives the same raised snapshots as the first attempt" do
    source = raised_load_checkpoint([raised_load_entry(id: 7, version: 0), raised_load_entry(id: 8, version: 0)])

    first_loaded = described_class.build(source:, corrections: [], stored: nil)
    first = described_class.raised_snapshots(source:, loaded: first_loaded, corrections: [])
    resumed_loaded = described_class.build(source:, corrections: [], stored: first_loaded)
    resumed = described_class.raised_snapshots(source:, loaded: resumed_loaded, corrections: [])

    expect(first.pluck("id")).to contain_exactly(7, 8)
    expect(resumed).to eq(first)
    expect(resumed_loaded.rows.fetch("entries").pluck("version").uniq)
      .to eq([Timekeeping::ReservationDerivation::CORRECTION_VERSION])
  end

  it "the cutover lists a locked change only for an entry whose nil legacy lock was loaded as false, under that entry's company" do
    source = raised_load_checkpoint([
      raised_load_entry(id: 7, version: 0, company_id: 1, locked: nil),
      raised_load_entry(id: 8, version: 0, company_id: 2, locked: false)
    ])
    loaded = described_class.build(source:, corrections: [], stored: nil)

    listed = described_class.listed_corrections(source:, loaded:, corrections: [])

    expect(loaded.rows.fetch("entries").to_h { |row| [row["id"], row["locked"]] }).to eq(7 => false, 8 => false)
    expect(raised_load_listing(listed.fetch(1))).to contain_exactly(
      [:entries, [7], "version"], [:projection, [7], "version"],
      [:entries, [7], "locked"], [:projection, [7], "locked"]
    )
    expect(raised_load_listing(listed.fetch(2))).to contain_exactly([:entries, [8], "version"], [:projection, [8], "version"])
  end

  it "a null legacy lock loaded as false is listed only under the company that owns the entry" do
    source = raised_load_checkpoint([
      raised_load_entry(id: 7, version: 0, company_id: 1, locked: nil),
      raised_load_entry(id: 8, version: 4, company_id: 2, locked: false)
    ])
    loaded = described_class.build(source:, corrections: [], stored: nil)

    expect(loaded.rows.fetch("entries").find { |row| row["id"] == 7 }.fetch("locked")).to be(false)

    listed = described_class.listed_corrections(source:, loaded:, corrections: [])

    expect(listed.keys).to eq([1])
    expect(raised_load_listing(listed.fetch(1))).to contain_exactly(
      [:entries, [7], "version"], [:projection, [7], "version"],
      [:entries, [7], "locked"], [:projection, [7], "locked"]
    )
  end
end

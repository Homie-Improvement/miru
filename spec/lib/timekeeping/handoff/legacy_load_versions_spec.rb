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

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions, "raised snapshots by company" do
  let(:checkpoint) { Timekeeping::Handoff::Checkpoint }

  def tenant_raised_entry(id:, company_id:)
    at = Time.utc(2026, 3, 2, 9, 0, 0, 123_456)
    checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => 0, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "same note",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  it "raised snapshots keep each entry's own company so the projection's company check can refuse a cross-tenant write" do
    entries = [tenant_raised_entry(id: 7, company_id: 1), tenant_raised_entry(id: 8, company_id: 2)]
    source = checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
    loaded = described_class.build(source:, corrections: [], stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    # Each snapshot must name the company that owns its entry; the monolith's
    # projection applies a snapshot only where that company matches.
    expect(snapshots.to_h { |snapshot| [snapshot.fetch("id"), snapshot.fetch("company_id")] }).to eq(7 => 1, 8 => 2)
    expect(snapshots).to all(satisfy { |snapshot| !snapshot.key?("version") })
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions, "null lock listing by company" do
  let(:checkpoint) { Timekeeping::Handoff::Checkpoint }

  def tenant_lock_entry(id:, company_id:, locked:)
    at = Time.utc(2026, 3, 2, 9)
    checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => 0, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  it "a null legacy lock loaded as false is listed only under its own company and never under another tenant" do
    entries = [tenant_lock_entry(id: 7, company_id: 1, locked: nil), tenant_lock_entry(id: 8, company_id: 2, locked: false)]
    source = checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
    loaded = described_class.build(source:, corrections: [], stored: nil)

    listed = described_class.listed_corrections(source:, loaded:, corrections: [])
    locked_listings = listed.transform_values do |corrections|
      corrections.select { |correction| correction.field == "locked" }.map { |correction| [correction.check, correction.row_key] }
    end

    expect(loaded.rows.fetch("entries").to_h { |row| [row["id"], row["locked"]] }).to eq(7 => false, 8 => false)
    expect(locked_listings.fetch(1)).to contain_exactly([:entries, [7]], [:projection, [7]])
    expect(locked_listings.fetch(2, [])).to be_empty
  end
end

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def raised_snapshot_spec_entry(id:, version:, company_id: 1, locked: false)
    at = Time.utc(2026, 3, 2, 9, 15, 30.123456r)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def raised_snapshot_spec_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  it "raised_snapshots gives a null-lock version-0 legacy entry one snapshot with its own timestamps, a false lock and no version" do
    # A snapshot accepts only true or false for locked, while a legacy row may hold nil;
    # an uncorrected entry has no reservation, so its loaded and relayed lock is false.
    null_lock = raised_snapshot_spec_entry(id: 7, version: 0, locked: nil)
    other_company = raised_snapshot_spec_entry(id: 9, version: 0, company_id: 2)
    unraised = raised_snapshot_spec_entry(id: 8, version: 4)
    source = raised_snapshot_spec_checkpoint([null_lock, unraised, other_company])
    loaded = described_class.build(source:, corrections: [], stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    expect(snapshots.size).to eq(2)
    expect(snapshots).to all(satisfy { |snapshot| !snapshot.key?("version") })
    by_id = snapshots.to_h { |snapshot| [snapshot["id"], snapshot] }
    expect(by_id.keys).to contain_exactly(7, 9)
    expect(by_id.fetch(7)).to eq(null_lock.except("version").merge("locked" => false))
    expect(by_id.fetch(7)["created_at"]).to eq(null_lock["created_at"])
    expect(by_id.fetch(7)["updated_at"]).to eq(null_lock["updated_at"])
    expect(by_id.fetch(9)["company_id"]).to eq(2)
    expect(loaded.rows.fetch("entries").find { |row| row["id"] == 7 }["locked"]).to be(false)
  end
end

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def resumed_raise_spec_entry(id:, version:)
    at = Time.utc(2026, 3, 2, 9)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => 1, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def resumed_raise_spec_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  it "raised_snapshots on a resumed load where Timekeeping already stores version 1 returns the same snapshots as the first load" do
    # A resumed checkpoint step rewrites the same snapshot set, so the entry the first
    # attempt already raised in Timekeeping must still get its snapshot, exactly once.
    source = resumed_raise_spec_checkpoint([resumed_raise_spec_entry(id: 7, version: 0)])
    first_load = described_class.build(source:, corrections: [], stored: nil)
    first = described_class.raised_snapshots(source:, loaded: first_load, corrections: [])

    resumed_load = described_class.build(source:, corrections: [], stored: first_load)
    resumed = described_class.raised_snapshots(source:, loaded: resumed_load, corrections: [])

    expect(first.map { |snapshot| snapshot["id"] }).to eq([7])
    expect(resumed).to eq(first)
  end
end

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def tenant_raised_entry(id:, company_id:, version:)
    at = Time.utc(2026, 3, 2, 9, 0, 0.123456r)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def tenant_raised_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  it "raised snapshots keep each entry under its own company and never carry another company's entry" do
    # Company 1 has a raised entry; company 2 has only an entry already at a loadable version.
    source = tenant_raised_checkpoint([
      tenant_raised_entry(id: 7, company_id: 1, version: 0),
      tenant_raised_entry(id: 8, company_id: 2, version: 4)
    ])
    loaded = described_class.build(source:, corrections: [], stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    expect(snapshots.map { |snapshot| snapshot.values_at("company_id", "id") }).to eq([[1, 7]])
    expect(snapshots).to all(satisfy { |snapshot| !snapshot.key?("version") })
  end
end

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def tenant_lock_entry(id:, company_id:, version:, locked:)
    at = Time.utc(2026, 3, 2, 9)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def tenant_lock_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  it "a null legacy lock loaded as false is listed only under the company that owns the entry" do
    source = tenant_lock_checkpoint([
      tenant_lock_entry(id: 7, company_id: 1, version: 0, locked: nil),
      tenant_lock_entry(id: 8, company_id: 2, version: 4, locked: false)
    ])
    loaded = described_class.build(source:, corrections: [], stored: nil)

    expect(loaded.rows.fetch("entries").find { |row| row["id"] == 7 }.fetch("locked")).to be(false)

    listed = described_class.listed_corrections(source:, loaded:, corrections: [])

    expect(listed.keys).to eq([1])
    expect(listed.fetch(1).map { |correction| [correction.check, correction.row_key, correction.field] })
      .to contain_exactly(
        [:entries, [7], "version"], [:projection, [7], "version"],
        [:entries, [7], "locked"], [:projection, [7], "locked"]
      )
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def raised_snapshot_entry(id:, version:, company_id: 1, locked: false)
    at = Time.utc(2026, 3, 2, 9, 15, 30, 123_456)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def raised_snapshot_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  it "raised_snapshots gives one snapshot per raised uncorrected entry, equal to the loaded row without version, and none for unraised or corrected entries" do
    raised = raised_snapshot_entry(id: 7, version: 0)
    unraised = raised_snapshot_entry(id: 8, version: 4)
    corrected = raised_snapshot_entry(id: 9, version: 0)
    corrections = [{
      "company_id" => 1, "entry_id" => 9, "generation" => 2, "captured_at" => Time.utc(2026, 10, 1),
      "snapshot" => corrected.merge("locked" => true, "version" => Timekeeping::ReservationDerivation::CORRECTION_VERSION)
    }]
    source = raised_snapshot_checkpoint([raised, unraised, corrected])
    loaded = described_class.build(source:, corrections:, stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections:)

    expect(snapshots.size).to eq(1)
    expect(snapshots.first).to eq(raised.except("version"))
    expect(snapshots.first.fetch("created_at")).to eq(Time.utc(2026, 3, 2, 9, 15, 30, 123_456))
    expect(snapshots.first.fetch("updated_at")).to eq(Time.utc(2026, 3, 2, 9, 15, 30, 123_456))
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def nil_lock_entry(id:, version:, locked:)
    at = Time.utc(2026, 3, 2, 9)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => 1, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def nil_lock_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  it "a raised entry whose legacy lock is nil is loaded and snapshotted with locked false, never nil" do
    source = nil_lock_checkpoint([nil_lock_entry(id: 7, version: 0, locked: nil)])

    loaded = described_class.build(source:, corrections: [], stored: nil)
    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    loaded_row = loaded.rows.fetch("entries").find { |row| row["id"] == 7 }
    expect(loaded_row.fetch("locked")).to be(false)
    expect(loaded_row.fetch("version")).to eq(1)
    expect(snapshots.size).to eq(1)
    expect(snapshots.first.fetch("locked")).to be(false)
    expect(snapshots.first).not_to have_key("version")
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def lock_listing_entry(id:, company_id:, locked:)
    at = Time.utc(2026, 3, 2, 9)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => 0, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  it "the cutover lists a locked change only for an entry whose nil legacy lock was loaded as false, under that entry's company" do
    checkpoint = Timekeeping::Handoff::Checkpoint
    source = checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge(
      "entries" => [lock_listing_entry(id: 7, company_id: 1, locked: nil), lock_listing_entry(id: 8, company_id: 2, locked: false)]
    ))
    loaded = described_class.build(source:, corrections: [], stored: nil)

    listed = described_class.listed_corrections(source:, loaded:, corrections: [])

    company_one = listed.fetch(1).map { |correction| [correction.check, correction.row_key, correction.field] }
    company_two = listed.fetch(2).map { |correction| [correction.check, correction.row_key, correction.field] }
    expect(company_one).to contain_exactly(
      [:entries, [7], "version"], [:projection, [7], "version"],
      [:entries, [7], "locked"], [:projection, [7], "locked"]
    )
    expect(company_two).to contain_exactly([:entries, [8], "version"], [:projection, [8], "version"])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def two_company_entry(id:, company_id:)
    at = Time.utc(2026, 3, 2, 9)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => 0, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "same note",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  it "raised_snapshots keeps each entry's own company across two companies and names each entry once" do
    checkpoint = Timekeeping::Handoff::Checkpoint
    source = checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge(
      "entries" => [two_company_entry(id: 7, company_id: 1), two_company_entry(id: 8, company_id: 2)]
    ))
    loaded = described_class.build(source:, corrections: [], stored: nil)

    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    expect(snapshots.map { |snapshot| snapshot.values_at("company_id", "id") }).to contain_exactly([1, 7], [2, 8])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  it "raised snapshots can share the correction write because the lowest loadable version equals the correction version" do
    expect(described_class).to respond_to(:raised_snapshots)
    expect(described_class::LOWEST_LOADABLE_VERSION).to eq(Timekeeping::ReservationDerivation::CORRECTION_VERSION)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def raised_null_lock_entry(id:, version:, company_id: 1, locked: false)
    at = Time.utc(2026, 3, 2, 9, 15, 30, 123_456)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def raised_null_lock_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  # A snapshot must carry true or false for locked; a null lock in a raised
  # snapshot would make Timekeeping refuse the whole snapshot write and leave
  # the cutover fenced on every resume.
  it "a raised legacy entry with a null lock is loaded and snapshotted with locked false, and the cutover lists that lock change" do
    source = raised_null_lock_checkpoint([raised_null_lock_entry(id: 7, version: 0, locked: nil)])

    loaded = described_class.build(source:, corrections: [], stored: nil)
    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])
    listed = described_class.listed_corrections(source:, loaded:, corrections: [])

    expect(loaded.rows.fetch("entries").first["locked"]).to be(false)
    expect(snapshots.size).to eq(1)
    expect(snapshots.first).not_to have_key("version")
    expect(snapshots.first["locked"]).to be(false)
    expect(listed.fetch(1).map { |correction| [correction.check, correction.field, correction.row_key] })
      .to include([:entries, "locked", [7]], [:projection, "locked", [7]])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def raised_only_entry(id:, version:, company_id: 1, locked: false)
    at = Time.utc(2026, 3, 2, 9, 15, 30, 123_456)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => locked,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def raised_only_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  # The correction snapshot and a raised snapshot for the same entry would
  # both be sent, and Timekeeping refuses a snapshot list naming an entry twice.
  it "a corrected entry never also gets a raised snapshot, so no entry is written twice at one generation" do
    corrected_row = raised_only_entry(id: 7, version: 0, locked: false)
    source = raised_only_checkpoint([corrected_row, raised_only_entry(id: 8, version: 0)])
    corrections = [{
      "company_id" => 1, "entry_id" => 7, "generation" => 2, "captured_at" => Time.utc(2026, 3, 3),
      "snapshot" => corrected_row.merge("locked" => true, "version" => Timekeeping::ReservationDerivation::CORRECTION_VERSION)
    }]

    loaded = described_class.build(source:, corrections:, stored: nil)
    snapshots = described_class.raised_snapshots(source:, loaded:, corrections:)

    expect(snapshots.pluck("id")).to eq([8])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def two_company_raised_entry(id:, version:, company_id:)
    at = Time.utc(2026, 3, 2, 9, 15, 30, 123_456)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => company_id, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def two_company_raised_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  # The projection applies a snapshot only where its company matches, and the
  # live rollback compares timestamps to the microsecond, so a snapshot must
  # keep the entry's own company and times.
  it "raised snapshots for two companies with identical entry data each keep their own company and exact timestamps, and an unraised entry gets none" do
    source = two_company_raised_checkpoint([
      two_company_raised_entry(id: 7, version: 0, company_id: 1),
      two_company_raised_entry(id: 8, version: 0, company_id: 2),
      two_company_raised_entry(id: 9, version: 4, company_id: 2)
    ])

    loaded = described_class.build(source:, corrections: [], stored: nil)
    snapshots = described_class.raised_snapshots(source:, loaded:, corrections: [])

    expect(snapshots.to_h { |snapshot| [snapshot["id"], snapshot["company_id"]] }).to eq(7 => 1, 8 => 2)
    expect(snapshots.pluck("created_at").uniq).to eq([Time.utc(2026, 3, 2, 9, 15, 30, 123_456)])
    expect(snapshots.pluck("updated_at").uniq).to eq([Time.utc(2026, 3, 2, 9, 15, 30, 123_456)])
    expect(snapshots).to all(satisfy { |snapshot| !snapshot.key?("version") })
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::LegacyLoadVersions do
  def resumed_raised_entry(id:, version:)
    at = Time.utc(2026, 3, 2, 9, 15, 30, 123_456)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }.merge(
      "id" => id, "company_id" => 1, "version" => version, "project_id" => 11, "user_id" => 21,
      "work_date" => Date.new(2026, 3, 2), "duration" => 60.0, "note" => "legacy entry",
      "bill_status" => "unbilled", "review_status" => "not_required", "locked" => false,
      "source" => "manual", "source_metadata" => {}, "proof_metadata" => {},
      "created_at" => at, "updated_at" => at
    )
  end

  def resumed_raised_checkpoint(entries)
    checkpoint = Timekeeping::Handoff::Checkpoint
    checkpoint.build(tables: checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entries))
  end

  # A resume reads the versions Timekeeping already stores from the first
  # attempt; the raised set must still come from the legacy source, or the
  # resumed write would drop entries and leave their projection at version 0.
  it "a resumed cutover that finds its raised versions already stored derives the same raised snapshots as the first attempt" do
    source = resumed_raised_checkpoint([resumed_raised_entry(id: 7, version: 0), resumed_raised_entry(id: 8, version: 0)])

    first_loaded = described_class.build(source:, corrections: [], stored: nil)
    first = described_class.raised_snapshots(source:, loaded: first_loaded, corrections: [])
    resumed_loaded = described_class.build(source:, corrections: [], stored: first_loaded)
    resumed = described_class.raised_snapshots(source:, loaded: resumed_loaded, corrections: [])

    expect(first.pluck("id")).to contain_exactly(7, 8)
    expect(resumed).to eq(first)
    expect(resumed_loaded.rows.fetch("entries").pluck("version").uniq)
      .to eq([Timekeeping::ReservationDerivation::CORRECTION_VERSION])
  end
end

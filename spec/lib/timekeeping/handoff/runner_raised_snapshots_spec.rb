# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Timekeeping::Handoff::Runner do
  context "more tests 2", :two_tenant_seed, :seeded_without_transaction do
    it "a first cutover resumed after its snapshots were written keeps exactly one version-1 snapshot for every raised or corrected legacy entry" do
      timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
      owners = TimekeepingHandoffFakes.owners(timekeeping:)
      report_root = Dir.mktmpdir("handoff-raised-snapshots")
      legacy_rows = Timekeeping::Handoff::LegacySource.new(
        connection: ActiveRecord::Base.connection,
        recorded_disposition: YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH)
      ).export(generation: 2, captured_at: Time.current.utc.floor(6))
      source_entries = legacy_rows.fetch(:checkpoint).rows.fetch("entries")
      corrected_ids = legacy_rows.fetch(:corrections).map { |correction| correction.fetch("entry_id") }
      raised_rows = source_entries.select { |row| row["version"] < 1 }.reject { |row| corrected_ids.include?(row["id"]) }
      expect(raised_rows).not_to be_empty

      expect do
        described_class.run(direction: :cutover, owners:, report_root:,
                            observer: TimekeepingHandoffHooks::Interrupt.new(at: :after_corrections))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      described_class.run(direction: :cutover, owners:, report_root:)

      expect(TimekeepingOwnership.current).to have_attributes(owner: "timekeeping", generation: 2, handoff_step: nil)
      stored = timekeeping.corrections
      stored_ids = stored.map { |snapshot| TimekeepingHandoffFakes::InMemoryTimekeepingStore.entry_id_of(snapshot) }
      expect(stored_ids).to match_array(raised_rows.pluck("id") + corrected_ids)
      expect(stored_ids.uniq.size).to eq(stored_ids.size)
      expect(stored.pluck("version").uniq).to eq([1])
      expect(stored.pluck("generation").uniq).to eq([2])

      by_id = stored.to_h { |snapshot| [snapshot["id"], snapshot.except("version", "generation")] }
      raised_rows.each do |row|
        expect(by_id.fetch(row["id"])).to eq(row.except("version").merge("locked" => row["locked"] == true))
      end
    end
  end

  context "more tests 3", :two_tenant_seed, :seeded_without_transaction do
    # The monolith's projection reaches version 1 only through a relayed snapshot, so
    # every legacy entry the load raises from version 0 must be written to Timekeeping's
    # outbox at the cutover. Otherwise a rollback finds "entries left at version 0 in
    # `timesheet_entries` while Timekeeping holds version 1".
    it "a first cutover writes exactly one snapshot for every legacy entry at version 0, keeping its company, a boolean lock and its exact timestamps" do
      legacy_rows = TimesheetEntry.unscoped.where(version: 0).pluck(:id, :created_at, :updated_at)
        .to_h { |id, created_at, updated_at| [id, [created_at, updated_at]] }
      expect(legacy_rows).not_to be_empty
      timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new

      described_class.run(direction: :cutover, owners: TimekeepingHandoffFakes.owners(timekeeping:),
                          report_root: Dir.mktmpdir("handoff-raised-snapshots"))

      expect(TimekeepingOwnership.current).to have_attributes(owner: "timekeeping", handoff_step: nil)
      written_ids = timekeeping.correction_writes.map do |snapshot|
        TimekeepingHandoffFakes::InMemoryTimekeepingStore.entry_id_of(snapshot)
      end
      expect(written_ids.tally.select { |_id, count| count > 1 }).to be_empty
      expect(written_ids).to include(*legacy_rows.keys)

      loaded_company = timekeeping.rows.fetch("entries").to_h { |row| [row["id"], row["company_id"]] }
      timekeeping.correction_writes.select { |snapshot| legacy_rows.key?(snapshot["id"]) }.each do |snapshot|
        expect(snapshot).not_to have_key("version")
        expect([true, false]).to include(snapshot["locked"])
        expect(snapshot["company_id"]).to eq(loaded_company.fetch(snapshot["id"]))
        created_at, updated_at = legacy_rows.fetch(snapshot["id"])
        expect(snapshot["created_at"].to_time.utc.iso8601(6)).to eq(created_at.utc.iso8601(6))
        expect(snapshot["updated_at"].to_time.utc.iso8601(6)).to eq(updated_at.utc.iso8601(6))
      end
    end
  end
end

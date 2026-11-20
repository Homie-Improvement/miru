# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Timekeeping::Handoff::Runner do
  context "more tests 2", :two_tenant_seed, :seeded_without_transaction do
    it "a rollback drained through the outbox relay leaves the projection at Timekeeping's versions and a repeated drain changes nothing" do
      timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
      owners = TimekeepingHandoffFakes.owners(timekeeping:, relay: :timekeeping_outbox)
      report_root = Pathname(Dir.mktmpdir("handoff-report"))

      described_class.run(direction: :cutover, owners:, report_root:)
      described_class.run(direction: :rollback, owners:, report_root:)

      expect(TimekeepingOwnership.current).to have_attributes(owner: "monolith", generation: 3, handoff_step: nil)
      reconciliation = JSON.parse(File.read(report_root.join("generation-3", "reconciliation.json")))
      expect(reconciliation.fetch("abort")).to be(false)

      projection = TimesheetEntry.unscoped.pluck(:id, :version).to_h
      timekeeping.rows.fetch("entries").each do |row|
        expect(projection.fetch(row["id"])).to eq(row["version"]), "entry #{row['id']} was left behind in the projection"
      end

      # Every outbox row was delivered once; draining again must deliver nothing and change nothing.
      relay = owners.fetch(:timekeeping).drain
      through = timekeeping.highest_outbox_position
      expect { relay.drain!(through:) }.not_to raise_error
      expect(relay.drained?(through:)).to be(true)
      expect(TimesheetEntry.unscoped.pluck(:id, :version).to_h).to eq(projection)
    ensure
      FileUtils.rm_rf(report_root) if report_root
    end
  end

  context "more tests 3", :two_tenant_seed, :seeded_without_transaction do
    # "Fake-path runner specs can use a test relay that delivers only Timekeeping's outbox snapshots through
    # `Timekeeping::ProjectionConsumer`, so a snapshot left out of the outbox leaves the projection behind and fails the spec."
    it "a raised entry's snapshot left out of Timekeeping's outbox leaves the projection behind and refuses the rollback at reconcile" do
      recorded_ids = YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH).fetch("companies").values
        .flat_map { |invoices| invoices.values.flat_map { |listing| listing.fetch("entry_ids") } }
      omitted = TimesheetEntry.unscoped.where(version: 0).where.not(id: recorded_ids).first
      expect(omitted).not_to be_nil
      omitted_id = omitted.id

      store_class = Class.new(TimekeepingHandoffFakes::InMemoryTimekeepingStore) do
        define_method(:write_correction_snapshots) do |snapshots:, version:, generation:|
          kept = snapshots.reject { |snapshot| self.class.entry_id_of(snapshot) == omitted_id }
          super(snapshots: kept, version:, generation:)
        end
      end
      timekeeping = store_class.new
      owners = TimekeepingHandoffFakes.owners(timekeeping:, relay: :timekeeping_outbox)
      report_root = Pathname(Dir.mktmpdir("handoff-report"))

      described_class.run(direction: :cutover, owners:, report_root:)
      expect(TimekeepingOwnership.current).to have_attributes(owner: "timekeeping", generation: 2, handoff_step: nil)
      expect(timekeeping.outbox.map { |row| row.dig("entry", "id") }).not_to include(omitted_id)

      # Refused, not a relay failure: the outbox relay delivered everything it held.
      expect do
        described_class.run(direction: :rollback, owners:, report_root:)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)

      ownership = TimekeepingOwnership.current
      expect(ownership.owner).to eq("timekeeping")
      expect(ownership.generation).to eq(3)
      expect(TimesheetEntry.unscoped.find(omitted_id).version).to eq(0)

      reconciliation = JSON.parse(File.read(report_root.join("generation-3", "reconciliation.json")))
      expect(reconciliation.fetch("abort")).to be(true)
      unlisted = reconciliation.fetch("companies").fetch(omitted.company_id.to_s).fetch("unlisted")
      expect(unlisted).to include(
        a_hash_including(
          "check" => "projection", "table" => "timesheet_entries", "row_key" => [omitted_id],
          "field" => "version", "reason" => "changed"
        )
      )
    ensure
      FileUtils.rm_rf(report_root) if report_root
    end
  end

  context "more tests 4", :two_tenant_seed, :seeded_without_transaction do
    it "a rollback drained only from Timekeeping's outbox through the projection consumer brings every raised entry's projection to Timekeeping's version and finishes" do
      raised_ids = TimesheetEntry.unscoped.where(version: 0).pluck(:id)
      expect(raised_ids).not_to be_empty
      timekeeping = TimekeepingHandoffFakes::InMemoryTimekeepingStore.new
      owners = TimekeepingHandoffFakes.owners(timekeeping:, relay: :timekeeping_outbox)
      report_root = Pathname(Dir.mktmpdir("handoff-report"))

      described_class.run(direction: :cutover, owners:, report_root:)
      outboxed = timekeeping.outbox.map { |row| row.dig("entry", "id") }
      expect(outboxed).to include(*raised_ids)

      described_class.run(direction: :rollback, owners:, report_root:)

      expect(TimekeepingOwnership.current).to have_attributes(owner: "monolith", generation: 3, handoff_step: nil)
      reconciliation = JSON.parse(File.read(report_root.join("generation-3", "reconciliation.json")))
      expect(reconciliation.fetch("abort")).to be(false)
      stored_versions = timekeeping.rows.fetch("entries").to_h { |row| [row["id"], row["version"]] }
      TimesheetEntry.unscoped.where(id: raised_ids).pluck(:id, :version).each do |id, version|
        expect(version).to eq(stored_versions.fetch(id)), "entry #{id} projection stayed at #{version}"
        expect(version).to be >= 1
      end
    ensure
      FileUtils.rm_rf(report_root) if report_root
    end
  end

  context "more tests 5", :two_tenant_seed, :seeded_without_transaction do
    # "Fake-path runner specs can use a test relay that delivers only Timekeeping's outbox snapshots through \`Timekeeping::ProjectionConsumer\`, so a snapshot left out of the outbox leaves the projection behind and fails the spec."
    it "a raised entry whose snapshot is left out of Timekeeping's outbox stops the rollback at reconcile with its projection version behind" do
      corrected_ids = YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH).fetch("companies").values
        .flat_map { |invoices| invoices.values.flat_map { |listing| listing.fetch("entry_ids") } }
      omitted = TimesheetEntry.unscoped.where(version: 0).where.not(id: corrected_ids).order(:id).first
      expect(omitted).not_to be_nil
      omitted_id = omitted.id

      store_class = Class.new(TimekeepingHandoffFakes::InMemoryTimekeepingStore) do
        define_method(:write_correction_snapshots) do |snapshots:, version:, generation:|
          super(snapshots: snapshots.reject { |snapshot| snapshot["id"] == omitted_id }, version:, generation:)
        end
      end
      timekeeping = store_class.new
      owners = TimekeepingHandoffFakes.owners(timekeeping:, relay: :timekeeping_outbox)
      report_root = Pathname(Dir.mktmpdir("handoff-report"))

      described_class.run(direction: :cutover, owners:, report_root:)
      expect(timekeeping.outbox.map { |row| row.fetch("entry").fetch("id") }).not_to include(omitted_id)

      # The failure must be the reconcile refusal, not a refused delivery.
      expect do
        described_class.run(direction: :rollback, owners:, report_root:)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)

      expect(TimekeepingOwnership.current).to have_attributes(owner: "timekeeping", generation: 3)
      expect(TimesheetEntry.unscoped.find(omitted_id).version).to eq(0)
      reconciliation = JSON.parse(File.read(report_root.join("generation-3", "reconciliation.json")))
      expect(reconciliation.fetch("abort")).to be(true)
      unlisted = reconciliation.fetch("companies").fetch(omitted.company_id.to_s).fetch("unlisted")
      expect(unlisted).to include(
        a_hash_including(
          "check" => "projection", "table" => "timesheet_entries", "row_key" => [omitted_id],
          "field" => "version", "reason" => "changed"
        )
      )
    ensure
      FileUtils.rm_rf(report_root) if report_root
    end
  end
end

# frozen_string_literal: true

require "rails_helper"

# A first cutover writes its correction snapshots before it flips ownership to
# Timekeeping. The relay must not deliver them until that flip admits their
# generation, and an aborted attempt's snapshots must not be left to be
# refused after a retry at a later generation flips.
RSpec.describe Timekeeping::Handoff::CorrectionSnapshots, "held until the flip" do
  include_context "timekeeping entry writes without transactional fixtures"

  let(:relay_source) { Timekeeping::RelayOutboxSource.new }

  def held_snapshot_entry
    now = Time.utc(2026, 3, 2, 9)
    Entry.create!(company_id: 4, project_id: 5, user_id: 7, work_date: Date.new(2026, 3, 2), duration: 45.0,
                  note: "", bill_status: "unbilled", version: 0, created_at: now, updated_at: now)
  end

  def offered_generations
    relay_source.unsent_after(0, 100).map { |row| row.fetch("generation") }
  end

  it "keeps correction snapshots from the relay until their generation is admitted" do
    entry = held_snapshot_entry
    Timekeeping::Admission.fence!

    described_class.write!(snapshots: [handoff_correction_snapshot(entry, locked: true)], version: 1, generation: 2)

    expect(OutboxSnapshot.where(id: entry.id, generation: 2).count).to eq(1)
    expect(offered_generations).to eq([])

    Timekeeping::Admission.admit!(generation: 2)

    expect(offered_generations).to eq([2])
    expect(Timekeeping::Admission.held_generation).to be_nil
  end

  it "removes an aborted attempt's undelivered snapshots when a retry writes at a later generation" do
    entry = held_snapshot_entry
    snapshot = handoff_correction_snapshot(entry, locked: true)
    Timekeeping::Admission.fence!

    described_class.write!(snapshots: [snapshot], version: 1, generation: 2)
    described_class.write!(snapshots: [snapshot], version: 1, generation: 3)

    expect(OutboxSnapshot.where(id: entry.id, sent_at: nil).pluck(:generation)).to eq([3])

    Timekeeping::Admission.admit!(generation: 3)

    expect(offered_generations).to eq([3])
  end

  it "removes held snapshots when a different generation is admitted, and leaves other rows alone" do
    entry = held_snapshot_entry
    snapshot = handoff_correction_snapshot(entry, locked: true)
    OutboxSnapshot.insert_all!([snapshot.merge("version" => 0, "generation" => 1)])
    Timekeeping::Admission.fence!

    described_class.write!(snapshots: [snapshot], version: 1, generation: 2)
    Timekeeping::Admission.admit!(generation: 3)

    expect(OutboxSnapshot.where(id: entry.id).order(:generation).pluck(:generation)).to eq([1])
    expect(offered_generations).to eq([1])
  end
end

# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# TimekeepingOwnership#snapshot_generation_accepted? trusts any stored final
# outbox position, and Runner#freeze reuses a stored position instead of
# capturing a new one. Closing admission clears the position, so it is the
# only thing that keeps a position left by an earlier handoff from opening
# the previous generation's snapshots during this one.
RSpec.describe Timekeeping::Handoff::Runner, "final outbox position left by an earlier handoff", :two_tenant_seed,
               :seeded_without_transaction do
  # The stale position is above the one this handoff stores, with a probe
  # between them: the stale one would accept the probe, the new one refuses it.
  stale_final_outbox_position = 40
  new_final_outbox_position = 5
  probe_positions = [new_final_outbox_position, new_final_outbox_position + 1, stale_final_outbox_position].freeze

  let(:calls) { [] }
  let(:clock) { Struct.new(:now).new(Time.utc(2026, 10, 27, 12)) }
  let(:cutover_root) { Pathname(Dir.mktmpdir("handoff-stale-position-cutover")) }
  let(:rollback_root) { Pathname(Dir.mktmpdir("handoff-stale-position-rollback")) }

  # The outgoing owner on rollback; its highest outbox position becomes the newly stored P.
  let(:timekeeping_store) do
    position = new_final_outbox_position
    Class.new(TimekeepingHandoffFakes::InMemoryTimekeepingStore) do
      define_method(:highest_outbox_position) { position }
    end.new
  end

  let(:monolith_store) { Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection) }

  # Relays as the shared fake does, but first asks the real ownership rule, as
  # the projection consumer does, whether each probe position of the previous
  # generation is accepted, and records the row state it asked under.
  let(:eligibility_checking_relay) do
    positions = probe_positions
    Class.new(TimekeepingHandoffFakeRelay) do
      attr_reader :eligibility_checks

      define_method(:drain!) do |through:|
        ownership = TimekeepingOwnership.current
        accepted = positions.map do |position|
          ownership.snapshot_generation_accepted?(generation: ownership.generation - 1, outbox_position: position)
        end
        (@eligibility_checks ||= []) << [ownership.handoff_step, ownership.final_outbox_position, accepted]
        super(through:)
      end
    end.new(store: timekeeping_store, log: calls)
  end

  let(:owners) do
    {
      "monolith" => Timekeeping::Handoff::Owner.new(
        name: "monolith", store: monolith_store, admission: TimekeepingHandoffFakes::RecordingAdmission.new,
        settle: TimekeepingHandoffFakes::NoOpSettle.new,
        drain: TimekeepingHandoffFakeRelay.new(store: monolith_store, log: calls)
      ),
      "timekeeping" => Timekeeping::Handoff::Owner.new(
        name: "timekeeping", store: timekeeping_store, admission: timekeeping_store,
        settle: TimekeepingHandoffFakes::NoOpSettle.new, drain: eligibility_checking_relay
      )
    }
  end

  it "clears the stale position when admission closes and drains against the newly stored one at settle" do
    # The first cutover drains through the legacy check, so only the rollback reaches the owner's drain.
    described_class.run(direction: :cutover, owners:, report_root: cutover_root, clock:)
    expect(TimekeepingOwnership.current.handoff_step).to be_nil

    # "A runner spec starts with an old final_outbox_position"
    TimekeepingOwnership.current.update_columns(final_outbox_position: stale_final_outbox_position)
    calls.clear

    # Freeze overwrites the position, so the clear is read right after step 1.
    row_after_close_admission = nil
    observer = lambda do |event, step:|
      next unless event == :after_step && step.to_s == "close_admission"

      ownership = TimekeepingOwnership.current
      row_after_close_admission = [ownership.generation, ownership.handoff_step, ownership.final_outbox_position]
    end

    described_class.run(direction: :rollback, owners:, report_root: rollback_root, clock:, observer:)

    # "closes admission, asserts the position is cleared"
    expect(row_after_close_admission).to eq([3, "close_admission", nil])

    # "has a drain check snapshot eligibility against the newly stored position while the row still records settle"
    expect(calls).to include([:drain, new_final_outbox_position])
    expect(eligibility_checking_relay.eligibility_checks).to eq(
      [["settle", new_final_outbox_position, [true, false, false]]]
    )

    ownership = TimekeepingOwnership.current
    expect([ownership.generation, ownership.owner, ownership.handoff_step]).to eq([3, "monolith", nil])
  end
end

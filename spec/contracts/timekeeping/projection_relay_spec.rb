# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingProjectionRelay do
  def projection_relay_prepare_owner
    TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
  end

  # Writes one entry through the prepared store's local owner, as an owner of
  # the company, and returns the stored Timekeeping::LocalEntry.
  def projection_relay_prepared_entry(company, note)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role("owner", company)
    project = create(:project, client: create(:client, company:))
    created = Timekeeping::LocalOwner.call(
      operation: :create, company_id: company.id, generation: TimekeepingOwnership.current.generation.to_s,
      actor: Timekeeping::LocalOwner::Actor.user(user_id: user.id, role: "owner"),
      params: { "idempotency_key" => SecureRandom.uuid,
                "body" => { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 30.0,
                            "note" => note, "source" => "manual", "source_metadata" => {} } }
    )
    expect(created.status).to be_between(200, 201)
    Timekeeping::LocalEntry.where(company_id: company.id).order(:id).last
  end

  it "relay_local_entries_to_projection projects each company's prepared entry under its own company_id only" do
    projection_relay_prepare_owner
    company_a = create(:company)
    company_b = create(:company)
    entry_a = projection_relay_prepared_entry(company_a, "company A private note")
    entry_b = projection_relay_prepared_entry(company_b, "company B private note")

    expect(relay_local_entries_to_projection(company_a)).to be_nil
    relay_local_entries_to_projection(company_b)

    # Each company's entry lands in the shared projection table under its own company and nowhere else.
    expect(TimesheetEntry.unscoped.find(entry_a.id)).to have_attributes(company_id: company_a.id,
                                                                         note: "company A private note")
    expect(TimesheetEntry.unscoped.find(entry_b.id)).to have_attributes(company_id: company_b.id,
                                                                         note: "company B private note")
    expect(TimesheetEntry.unscoped.where(company_id: company_a.id).pluck(:note)).to eq(["company A private note"])
    expect(TimesheetEntry.unscoped.where(company_id: company_b.id).pluck(:note)).to eq(["company B private note"])
  end

  it "relay_local_entries_to_projection raises only for the company whose outbox row stays unsent" do
    projection_relay_prepare_owner
    company_a = create(:company)
    entry_a = projection_relay_prepared_entry(company_a, "company A entry")

    # Company B's only outbox row carries an incomplete snapshot, so the consumer refuses it and it stays unsent.
    company_b = create(:company)
    payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
      "id" => 9_486_001, "company_id" => company_b.id, "duration" => 45.0, "version" => 1
    )
    refused_row = Timekeeping::LocalOutboxEntry.create!(company_id: company_b.id, entry_id: 9_486_001, generation: 1,
                                                        payload:, created_at: Time.current)

    # Another company's refused row must not fail this company's delivery.
    expect { relay_local_entries_to_projection(company_a) }.not_to raise_error
    expect(TimesheetEntry.unscoped.find(entry_a.id).company_id).to eq(company_a.id)
    expect(Timekeeping::LocalOutboxEntry.where(company_id: company_a.id, sent_at: nil)).not_to exist

    expect { relay_local_entries_to_projection(company_b) }
      .to raise_error(TimekeepingProjectionRelay::Undelivered, /company #{company_b.id}/)
    expect(refused_row.reload.sent_at).to be_nil
    expect(TimesheetEntry.unscoped.where(id: 9_486_001)).not_to exist
  end

  it "relay_local_entries_to_projection delivers a prepared-store entry with its multi-line note and marks the outbox sent", owner_state: "rollback" do
    projection_relay_prepare_owner
    company = create(:company)
    note = "Programming - Built landing\nand tests"
    entry = projection_relay_prepared_entry(company, note)
    expect(Timekeeping::LocalEntry.where(company_id: company.id).count).to eq(1)
    expect(TimesheetEntry.unscoped.where(id: entry.id)).not_to exist

    expect(relay_local_entries_to_projection(company)).to be_nil

    projected = TimesheetEntry.unscoped.find(entry.id)
    expect(projected).to have_attributes(note:, duration: 30.0, company_id: company.id)
    expect(Timekeeping::LocalOutboxEntry.where(company_id: company.id, sent_at: nil)).not_to exist

    relay_local_entries_to_projection(company)
    expect(TimesheetEntry.unscoped.where(id: entry.id).count).to eq(1)
  end

  it "relay_local_entries_to_projection makes no relay call when the legacy store owns entries", owner_state: "legacy" do
    company = create(:company)
    allow(Timekeeping::RelayJob).to receive(:perform_now)

    expect(relay_local_entries_to_projection(company)).to be_nil

    expect(Timekeeping::RelayJob).not_to have_received(:perform_now)
  end

  it "relay helper raises when the generation moved after the write instead of leaving the row silently missing" do
    projection_relay_prepare_owner
    company = create(:company)
    entry_id = projection_relay_prepared_entry(company, "written before the move").id

    # The consumer refuses snapshots of an earlier generation, so delivery after the move must fail loudly.
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).increment!(:generation)

    expect { relay_local_entries_to_projection(company) }
      .to raise_error(TimekeepingProjectionRelay::Undelivered, /company #{company.id}/)
    expect(TimesheetEntry.unscoped.where(id: entry_id)).not_to exist
    expect(Timekeeping::LocalOutboxEntry.where(company_id: company.id, sent_at: nil)).to exist
  end

  it "deliver_live_snapshots! retries a drain that answered false and returns once every snapshot through the highest outbox position is delivered" do
    store_class = Class.new do
      attr_reader :drained_through

      def initialize
        @drained_through = []
        @answers = [false, true]
      end

      def highest_outbox_position
        17
      end

      def drain(through:)
        @drained_through << through
        @answers.shift
      end
    end
    store = store_class.new
    answers = double("answers", answer_for: nil)
    ticks = (0..100).to_a
    clock = -> { ticks.shift }

    # Drain answers false while another run holds the relay lock, so one false is retried, not treated as
    # delivered or failed.
    result = described_class.deliver_live_snapshots!(store:, answers:, company_id: 42, deadline_seconds: 30, clock:)

    expect(result).to be_nil
    expect(store.drained_through).to eq([17, 17])
  end

  it "deliver_live_snapshots! raises Undelivered with the consumer's refusal when the drain never finishes before the deadline" do
    store = double("store", highest_outbox_position: 5)
    allow(store).to receive(:drain).with(through: 5).and_return(false)
    refusal = TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" })
    answers = double("answers")
    allow(answers).to receive(:answer_for).with(42).and_return(refusal)
    now = 0.0
    clock = -> { now += 10.0 }

    # An undelivered snapshot must fail loudly, never read as delivered, so a reimport cannot silently store a duplicate.
    expect do
      described_class.deliver_live_snapshots!(store:, answers:, company_id: 42, deadline_seconds: 30, clock:)
    end.to raise_error(TimekeepingProjectionRelay::Undelivered, /company 42.*409.*stale_generation/m)
    expect(store).to have_received(:drain).with(through: 5).at_least(:once)
  end

  it "deliver_live_snapshots! names only the waiting company and never reports another company's consumer answer as its own" do
    waiting_company_id = 9_558_201
    other_company_id = 9_558_202
    other_refusal = TimekeepingRelay::Response.new(status: 409, body: { "reason" => "other_company_private_refusal" })
    answers = Class.new do
      define_method(:answer_for) { |company_id| company_id == other_company_id ? other_refusal : nil }
    end.new
    store = Class.new do
      def highest_outbox_position = 7
      def drain(through:) = false
    end.new
    ticks = [0.0, 100.0, 200.0, 300.0].each
    clock = -> { ticks.next rescue 400.0 }

    expect do
      described_class.deliver_live_snapshots!(store:, answers:, company_id: waiting_company_id,
                                              deadline_seconds: 30, clock:)
    end.to raise_error(TimekeepingProjectionRelay::Undelivered) { |error|
      expect(error.message).to include(waiting_company_id.to_s)
      expect(error.message).not_to include(other_company_id.to_s)
      expect(error.message).not_to include("other_company_private_refusal")
    }
  end

  # "Have run_harvest_import wait for that delivery and verify it in the timekeeping state, the same way it runs the relay in rollback."
  it "relay_local_entries_to_projection drains the live outbox in the timekeeping state while the live adapter runs", owner_state: "timekeeping" do
    TimekeepingOwnerState.apply!("timekeeping")
    company = create(:company)
    live = double("live instance", base_url: "http://127.0.0.1:4781", service_token: "relay-live-token")
    allow(TimekeepingRegressionAdapter).to receive_messages(current: live, snapshot_app: double("snapshot app", answer_for: nil))
    store = instance_double(Timekeeping::Handoff::TimekeepingStore, highest_outbox_position: 5)
    allow(store).to receive(:drain).with(through: 5).and_return(true)
    allow(Timekeeping::Handoff::TimekeepingStore).to receive(:new)
      .with(base_url: "http://127.0.0.1:4781", token: "relay-live-token").and_return(store)
    allow(Timekeeping::RelayJob).to receive(:perform_now)

    expect(relay_local_entries_to_projection(company)).to be_nil

    expect(store).to have_received(:drain).with(through: 5)
    # The rollback relay of the monolith's own prepared outbox does not run in the timekeeping state.
    expect(Timekeeping::RelayJob).not_to have_received(:perform_now)
  end

  it "relay_local_entries_to_projection raises Undelivered with the consumer's refusal when the live outbox never drains in the timekeeping state" do
    TimekeepingOwnerState.apply!("timekeeping")
    company = create(:company)
    live = instance_double(TimekeepingLiveInstance, base_url: "http://127.0.0.1:1", service_token: "live-token")
    refusal = TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" })
    snapshot_app = instance_double(TimekeepingLiveSnapshotApp, answer_for: refusal)
    allow(TimekeepingRegressionAdapter).to receive_messages(current: live, snapshot_app:)
    allow_any_instance_of(Timekeeping::Handoff::TimekeepingStore).to receive(:highest_outbox_position).and_return(7)
    allow_any_instance_of(Timekeeping::Handoff::TimekeepingStore).to receive(:drain).and_return(false)
    # The first clock read starts the wait; every later read is past any deadline.
    allow(Process).to receive(:clock_gettime).and_return(0.0, 1_000.0)
    allow(Timekeeping::RelayJob).to receive(:perform_now)

    expect { relay_local_entries_to_projection(company) }
      .to raise_error(TimekeepingProjectionRelay::Undelivered, /company #{company.id}.*409/m)
    # The rollback relay is not what verifies the timekeeping state.
    expect(Timekeeping::RelayJob).not_to have_received(:perform_now)
  end
end

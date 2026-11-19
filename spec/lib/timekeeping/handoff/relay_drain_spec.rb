# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Handoff::RelayDrain do
  def relay_drain_spec_row(company, entry_id)
    payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
      "id" => entry_id, "company_id" => company.id, "duration" => 45.0, "version" => 1
    )
    Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id:, generation: 1, payload:, created_at: Time.current)
  end

  # The projection endpoint accepts every batch, so the relay marks each row it sends.
  def relay_drain_spec_accepting_endpoint
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
  end

  it "drained?(through: P) is false until the projection holds P and an unsent row above P does not matter" do
    company = create(:company)
    at_or_below = [relay_drain_spec_row(company, 3601), relay_drain_spec_row(company, 3602)]
    p_position = at_or_below.last.outbox_position
    above = relay_drain_spec_row(company, 3603)
    relay_drain_spec_accepting_endpoint
    drain = described_class.new(owner: described_class::MonolithPort.new)

    # "`drained?(through: P)` is true only when no outbox row at or below P has `sent_at` NULL."
    expect(drain.drained?(through: p_position)).to be(false)

    drain.drain!(through: p_position)

    expect(at_or_below.map { |row| row.reload.sent_at }).to all(be_present)
    expect(drain.drained?(through: p_position)).to be(true)

    # "An unsent row above P does not matter."
    above.update_columns(sent_at: nil)
    expect(drain.drained?(through: p_position)).to be(true)
    at_or_below.first.update_columns(sent_at: nil)
    expect(drain.drained?(through: p_position)).to be(false)
  end

  it "with the relay advisory lock held drained? stays false after drain! returns" do
    company = create(:company)
    row = relay_drain_spec_row(company, 3701)
    p_position = row.outbox_position
    relay_drain_spec_accepting_endpoint
    drain = described_class.new(owner: described_class::MonolithPort.new)
    key = Timekeeping::RelayJob::RELAY_LOCK_KEY

    # The lock is held on another session: the session that holds an advisory
    # lock can take it again, so holding it on the relay's own connection
    # would not stop the relay.
    holder = ActiveRecord::Base.connection_pool.checkout
    begin
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_lock(?)", key]))
      drain.drain!(through: p_position)

      # "With the relay advisory lock held, `drained?` stays false."
      # "`drain!` returning is never the signal."
      expect(drain.drained?(through: p_position)).to be(false)
      expect(row.reload.sent_at).to be_nil
    ensure
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_unlock(?)", key]))
      ActiveRecord::Base.connection_pool.checkin(holder)
    end

    drain.drain!(through: p_position)
    expect(drain.drained?(through: p_position)).to be(true)
  end

  it "an unsent row above P does not change drained?(through: P), but an unsent row at P does" do
    company = create(:company)
    rows = [201, 202, 203].map { |entry_id| relay_drain_spec_row(company, entry_id) }
    through = rows[1].outbox_position
    relay_runs = 0
    # The relay never runs, so the answer can only come from the stored rows.
    drain = described_class.new(owner: described_class::MonolithPort.new(relay: -> { relay_runs += 1 }))

    rows[0].update_columns(sent_at: Time.current)
    expect(drain.drained?(through:)).to be(false)

    rows[1].update_columns(sent_at: Time.current)
    expect(rows[2].reload.sent_at).to be_nil
    # "An unsent row above P does not matter."
    expect(drain.drained?(through:)).to be(true)
    expect(relay_runs).to eq(0)
  end

  it "the Timekeeping drain port is drained only when the drain endpoint answers true" do
    store = instance_double(Timekeeping::Handoff::TimekeepingStore)
    answers = [false, false, true]
    allow(store).to receive(:drain) { answers.shift }
    drain = described_class.new(owner: described_class::TimekeepingPort.new(store:))

    # "Timekeeping's come from the drain endpoint's answer. `drain!` returning is never the signal."
    drain.drain!(through: 40)
    expect(drain.drained?(through: 40)).to be(false)
    expect(drain.drained?(through: 40)).to be(true)
    expect(store).to have_received(:drain).with(through: 40).exactly(3).times
  end
end

require "rails_helper"

RSpec.describe Timekeeping::Handoff::RelayDrain do
  context "more tests 2" do
  it "drained?(through: P) is false until the projection holds P and an unsent row above P does not matter" do
    company = create(:company)
    row_for = lambda do |entry_id|
      payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
        "id" => entry_id, "company_id" => company.id, "duration" => 45.0, "version" => 1
      )
      Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id:, generation: 1, payload:, created_at: Time.current)
    end
    at_or_below = [row_for.call(3601), row_for.call(3602)]
    p_position = at_or_below.last.outbox_position
    above = row_for.call(3603)
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
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
  end

  context "more tests 3" do
  it "with the relay advisory lock held drained? stays false after drain! returns" do
    company = create(:company)
    payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
      "id" => 3701, "company_id" => company.id, "duration" => 45.0, "version" => 1
    )
    row = Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id: 3701, generation: 1, payload:, created_at: Time.current)
    p_position = row.outbox_position
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
    drain = described_class.new(owner: described_class::MonolithPort.new)
    key = Timekeeping::RelayJob::RELAY_LOCK_KEY

    holder = ActiveRecord::Base.connection_pool.checkout
    begin
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_lock(?)", key]))
      drain.drain!(through: p_position)

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
  end

  context "more tests 4" do
  it "drained?(through: P) is false until the projection holds P" do
    company = create(:company)
    rows = [101, 102].map do |entry_id|
      payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
        "id" => entry_id, "company_id" => company.id, "duration" => 45.0, "version" => 1
      )
      Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id:, generation: 1, payload:, created_at: Time.current)
    end
    through = rows.last.outbox_position
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
    drain = described_class.new(owner: described_class::MonolithPort.new)

    # "`drained?(through: P)` is true only when no outbox row at or below P has `sent_at` NULL."
    expect(drain.drained?(through:)).to be(false)

    drain.drain!(through:)

    expect(rows.map { |row| row.reload.sent_at }).to all(be_present)
    expect(drain.drained?(through:)).to be(true)
  end
  end

  context "more tests 5" do
  it "an unsent row above P does not change drained?(through: P), but an unsent row at P does" do
    company = create(:company)
    rows = [201, 202, 203].map do |entry_id|
      payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
        "id" => entry_id, "company_id" => company.id, "duration" => 45.0, "version" => 1
      )
      Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id:, generation: 1, payload:, created_at: Time.current)
    end
    through = rows[1].outbox_position
    relay_runs = 0
    drain = described_class.new(owner: described_class::MonolithPort.new(relay: -> { relay_runs += 1 }))

    rows[0].update_columns(sent_at: Time.current)
    expect(drain.drained?(through:)).to be(false)

    rows[1].update_columns(sent_at: Time.current)
    expect(rows[2].reload.sent_at).to be_nil
    # "An unsent row above P does not matter."
    expect(drain.drained?(through:)).to be(true)
    expect(relay_runs).to eq(0)
  end
  end

  context "more tests 6" do
  it "with the relay advisory lock held drained? stays false after drain! returns" do
    company = create(:company)
    payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
      "id" => 301, "company_id" => company.id, "duration" => 45.0, "version" => 1
    )
    row = Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id: 301, generation: 1, payload:,
                                                created_at: Time.current)
    through = row.outbox_position
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
    drain = described_class.new(owner: described_class::MonolithPort.new)
    lock_key = Timekeeping::RelayJob::RELAY_LOCK_KEY

    holder = ActiveRecord::Base.connection_pool.checkout
    begin
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_lock(?)", lock_key]))
      # "`drain!` returning is never the signal."
      drain.drain!(through:)
      expect(drain.drained?(through:)).to be(false)
    ensure
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_unlock(?)", lock_key]))
      ActiveRecord::Base.connection_pool.checkin(holder)
    end

    drain.drain!(through:)
    expect(drain.drained?(through:)).to be(true)
  end
  end

  context "more tests 7" do
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

  context "more tests 8", "relay lock held" do
  it "drained? stays false after drain! while another session holds the relay advisory lock" do
    company = create(:company)
    payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
      "id" => 501, "company_id" => company.id, "duration" => 45.0, "version" => 1
    )
    row = Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id: 501, generation: 1, payload:,
                                                created_at: Time.current)
    through = row.outbox_position
    endpoint = Object.new
    endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
    end
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
    drain = described_class.new(owner: described_class::MonolithPort.new(relay: -> { Timekeeping::RelayJob.perform_now }))
    key = Timekeeping::RelayJob::RELAY_LOCK_KEY

    holder = ActiveRecord::Base.connection_pool.checkout
    begin
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_lock(?)", key]))
      drain.drain!(through:)
      # "With the relay advisory lock held, `drained?` stays false."
      # "`drain!` returning is never the signal."
      expect(drain.drained?(through:)).to be(false)
      expect(row.reload.sent_at).to be_nil
    ensure
      holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_unlock(?)", key]))
      ActiveRecord::Base.connection_pool.checkin(holder)
    end

    drain.drain!(through:)
    expect(drain.drained?(through:)).to be(true)
  end
  end

  context "more tests 9", "rows around P" do
  it "drained? ignores an unsent row above P but not an unsent row at P" do
    company = create(:company)
    create_row = lambda do |entry_id|
      payload = Timekeeping::SnapshotBatch::ENTRY_FIELDS.index_with { nil }.merge(
        "id" => entry_id, "company_id" => company.id, "duration" => 45.0, "version" => 1
      )
      Timekeeping::LocalOutboxEntry.create!(company_id: company.id, entry_id:, generation: 1, payload:,
                                            created_at: Time.current)
    end
    below = create_row.call(601)
    at_p = create_row.call(602)
    above = create_row.call(603)
    through = at_p.outbox_position
    # Nothing is relayed here, so the answer can only come from the stored rows.
    drain = described_class.new(owner: described_class::MonolithPort.new(relay: -> { }))

    below.update_columns(sent_at: Time.current)
    # "`drained?(through: P)` is true only when no outbox row at or below P has `sent_at` NULL."
    expect(drain.drained?(through:)).to be(false)

    at_p.update_columns(sent_at: Time.current)
    # "An unsent row above P does not matter."
    expect(above.reload.sent_at).to be_nil
    expect(drain.drained?(through:)).to be(true)
  end
  end
end

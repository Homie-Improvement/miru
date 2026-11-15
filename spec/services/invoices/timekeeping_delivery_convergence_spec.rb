# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoices::OutboxDelivery, "Timekeeping delivery convergence" do
  # "A lost commit answer is redelivered and applies once"
  # "The wrapper forwards the call to the fake, so the fake really applies it, then raises `Timekeeping::ReservationHttp::Error`."
  it "a lost commit answer is redelivered and applies once" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = 7
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_ids = Array.new(2) { fake.add_entry(company_id:, user_id:, project_id:)["id"] }
    invoice_id = 88_401
    operation_id = SecureRandom.uuid
    InvoiceOperationIntent.create!(
      company_id:, invoice_id:, operation_id:, state: "committed", generation: 7,
      disposition: "active", desired_entry_ids: entry_ids
    )
    row = InvoiceOperationOutboxItem.create!(
      company_id:, invoice_id:, operation_id:, kind: "commit",
      payload: {
        "company_id" => company_id, "invoice_id" => invoice_id, "operation_id" => operation_id,
        "generation" => 7, "disposition" => "active", "desired_entry_ids" => entry_ids
      }
    )
    commits_seen = 0
    http = TimekeepingContract::DroppingHttp.new(
      TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil),
      drop: ->(_method, path) { path.end_with?("/reservations/commit") && (commits_seen += 1) == 1 }
    )
    after_first = nil
    snapshot = nil

    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      client = Timekeeping::ReservationClient.new(http:)
      request = Invoices::ReservationRequest.new(
        company_id:, invoice_id:, operation_id:, generation: 7, disposition: "active", entries: entry_ids
      )
      expect(client.prepare(request).state).to eq("prepared")
      delivery = described_class.new(adapter_source: -> { client })

      delivery.deliver(row.id)
      after_first = row.reload.attributes
      # The fake applied the dropped commit before its answer was lost.
      snapshot = entry_ids.index_with { |id| [fake.reservations_for(id), fake.entry_locked?(id)] }

      delivery.deliver(row.id)
    end

    expect(snapshot.values.map(&:first)).to all(eq([{ "invoice_id" => invoice_id, "state" => "committed" }]))
    expect(after_first["delivered_at"]).to be_nil
    expect(after_first["undeliverable_at"]).to be_nil
    expect(after_first["attempts"]).to eq(1)

    expect(row.reload.delivered_at).to be_present
    commits = fake.requests.select { |sent| sent[:path].end_with?("/reservations/commit") }
    expect(commits.size).to eq(2)
    expect(commits.pluck(:body).uniq.size).to eq(1)
    # Redelivery changed no reservation: each entry holds exactly one committed reservation.
    expect(entry_ids.index_with { |id| [fake.reservations_for(id), fake.entry_locked?(id)] }).to eq(snapshot)
  end
end

RSpec.describe Invoices::OperationCoordinator, "with a dropped prepare answer from the Timekeeping fake", committed_data: true do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "Lost responses and a crash after prepare over committed data converge: after abort, each entry's reservation state equals its state before the save"
  # "Abort delivery first replays the identical prepare (same operation_id and body), then aborts. A prepare whose answer was lost is then terminal, and a late copy cannot reserve."
  it "the fake applies prepare but the answer is dropped: the save fails, and after abort each entry's reservation state equals its state before the save" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = TimekeepingOwnership.current.generation
    company = create(:company)
    invoice = create(:invoice, company:, client: create(:client, company:))
    entry_ids = Array.new(2) { fake.add_entry(company_id: company.id, user_id: 1, project_id: 1)["id"] }.sort
    state_of = -> { entry_ids.index_with { |id| [fake.reservations_for(id), fake.entry_locked?(id)] } }
    before_save = state_of.call

    # Records what the fake holds right after it answers the first prepare,
    # so the test proves the dropped prepare really reserved the entries.
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
    locked_after_first_prepare = nil
    observed_http = Object.new
    observed_http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      fake_client.call(method, path, headers:, body:).tap do
        if path.end_with?("/reservations/prepare")
          locked_after_first_prepare ||= entry_ids.map { |id| fake.entry_locked?(id) }
        end
      end
    end
    prepares_seen = 0
    dropping_http = TimekeepingContract::DroppingHttp.new(
      observed_http,
      drop: lambda { |_method, path| path.end_with?("/reservations/prepare") && (prepares_seen += 1) == 1 }
    )
    client = Timekeeping::ReservationClient.new(http: dropping_http)
    request = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: "active", entries: entry_ids
    )
    original_reference = invoice.reference

    expect do
      ApplicationRecord.transaction do
        invoice.update_column(:reference, "dropped-prepare-should-not-persist")
        described_class.new(reservations: client).call(request, holding: { entry_ids: request.entries, disposition: "active" })
      end
    end.to raise_error(StandardError)

    expect(locked_after_first_prepare).to eq([true, true])
    expect(invoice.reload.reference).to eq(original_reference)
    rows = InvoiceOperationOutboxItem.where(company_id: company.id, operation_id: request.operation_id)
    expect(rows.pluck(:kind)).to eq(["abort"])
    expect(InvoiceOperationIntent.find_by!(company_id: company.id, operation_id: request.operation_id).state).to eq("failed")

    DeliverInvoiceOperationJob.perform_now(rows.first.id, reservations: client)

    expect(rows.first.reload.delivered_at).to be_present
    expect(state_of.call).to eq(before_save)

    # A late copy of the identical prepare must not reserve anything again.
    client.prepare(request)
    expect(state_of.call).to eq(before_save)
  end
end

RSpec.describe RecoverInvoiceOperationIntentsJob, "after a crash between prepare and step 3 against the Timekeeping fake", committed_data: true do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "Lost responses and a crash after prepare over committed data converge: after abort, each entry's reservation state equals its state before the save"
  it "a crash between prepare and step 3 leaves the intent pending, and RecoverInvoiceOperationIntentsJob fails it and aborts" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = TimekeepingOwnership.current.generation
    company = create(:company)
    invoice = create(:invoice, company:, client: create(:client, company:))
    entry_ids = Array.new(2) { fake.add_entry(company_id: company.id, user_id: 1, project_id: 1)["id"] }.sort
    state_of = -> { entry_ids.index_with { |id| [fake.reservations_for(id), fake.entry_locked?(id)] } }
    before_save = state_of.call
    client = Timekeeping::ReservationClient.new(http: TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil))
    request = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: "active", entries: entry_ids
    )

    # The save wrote its pending intent and prepared, then crashed before step 3,
    # past the recovery pickup age.
    intent = InvoiceOperationIntent.create!(
      company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id, state: "pending",
      generation: request.generation, disposition: "active", desired_entry_ids: entry_ids, created_at: 61.seconds.ago
    )
    expect(client.prepare(request).state).to eq("prepared")
    expect(entry_ids.map { |id| fake.entry_locked?(id) }).to eq([true, true])

    described_class.perform_now(reservations: client)

    expect(intent.reload.state).to eq("failed")
    rows = InvoiceOperationOutboxItem.where(company_id: company.id, operation_id: request.operation_id)
    expect(rows.pluck(:kind)).to eq(["abort"])
    expect(rows.first.delivered_at).to be_present
    expect(state_of.call).to eq(before_save)
  end
end

RSpec.describe Invoices::OperationCoordinator, "with a step-3 guard that matches no row under the Timekeeping client", committed_data: true do
  around do |example|
    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) { example.run }
  end

  # "Commit the invoice change, the intent's change to `committed` (guarded by `WHERE state = 'pending'`) and the commit outbox row in one transaction."
  # "A step-3 guarded update matching no row rolls back the invoice change and writes no commit row"
  it "a step-3 guarded update matching no row rolls back the invoice change and writes no commit row" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = TimekeepingOwnership.current.generation
    company = create(:company)
    invoice = create(:invoice, company:, client: create(:client, company:))
    entry_ids = Array.new(2) { fake.add_entry(company_id: company.id, user_id: 1, project_id: 1)["id"] }.sort
    request = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: "active", entries: entry_ids
    )

    # After the fake answers prepare, another connection moves the intent out of
    # pending, so the save's guarded update to committed finds no row.
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
    run_on_other_connection = method(:committed_data_thread)
    step_three_http = Object.new
    step_three_http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      fake_client.call(method, path, headers:, body:).tap do
        next unless path.end_with?("/reservations/prepare")

        run_on_other_connection.call do
          InvoiceOperationIntent
            .where(company_id: request.company_id, operation_id: request.operation_id, state: "pending")
            .update_all(state: "failed", finished_at: Time.current)
        end.join
      end
    end
    client = Timekeeping::ReservationClient.new(http: step_three_http)
    original_reference = invoice.reference

    expect do
      ApplicationRecord.transaction do
        invoice.update_column(:reference, "step-three-should-not-persist")
        described_class.new(reservations: client).call(request, holding: { entry_ids: request.entries, disposition: "active" })
      end
    end.to raise_error(Invoices::OperationErrors::IntentNotPending)

    expect(invoice.reload.reference).to eq(original_reference)
    expect(
      InvoiceOperationOutboxItem.where(company_id: company.id, operation_id: request.operation_id, kind: "commit")
    ).not_to exist
    expect(InvoiceOperationIntent.find_by!(company_id: company.id, operation_id: request.operation_id).state).to eq("failed")
  end
end

RSpec.describe Invoices::OutboxDelivery, "lost prepare answer then a late copy" do
  it "timekeeping client: a prepare the fake applied but whose answer was lost is aborted back to the entry's prior state, and a late copy of it reserves nothing" do
    fake = TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key)
    fake.generation = 7
    company_id = fake.add_company
    user_id = fake.add_user(company_id:, role: "admin")
    project_id = fake.add_project(company_id:)
    entry_id = fake.add_entry(company_id:, user_id:, project_id:)["id"]
    invoice_id = 9601
    operation_id = SecureRandom.uuid
    request = Invoices::ReservationRequest.new(
      company_id:, invoice_id:, operation_id:, generation: 7, disposition: "active", entries: [entry_id]
    )
    locked_before = fake.entry_locked?(entry_id)
    reservations_before = fake.reservations_for(entry_id)

    with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV => timekeeping_key_pair.to_pem) do
      fake_http = TimekeepingContract::FakeClient.new(timekeeping: fake, relay: nil)
      # Only the save's first prepare loses its answer; the replays abort delivery sends are answered.
      dropped = false
      drop_first_prepare = lambda do |_method, path|
        next false if dropped || !path.end_with?("/reservations/prepare")

        dropped = true
      end
      dropping_client = Timekeeping::ReservationClient.new(
        http: TimekeepingContract::DroppingHttp.new(fake_http, drop: drop_first_prepare)
      )

      lost = dropping_client.prepare(request)

      expect(lost.state).to eq("retryable")
      # The wrapper forwards before it raises, so the fake really holds the entry now.
      expect(fake.entry_locked?(entry_id)).to be(true)

      # The save failed: its intent is failed and its abort row waits for delivery.
      InvoiceOperationIntent.create!(
        company_id:, invoice_id:, operation_id:, state: "failed", generation: 7,
        disposition: "active", desired_entry_ids: [entry_id]
      )
      item = InvoiceOperationOutboxItem.create!(
        company_id:, invoice_id:, operation_id:, kind: "abort",
        payload: { company_id:, invoice_id:, operation_id:, generation: 7, disposition: "active", desired_entry_ids: [entry_id] }
      )

      described_class.new(adapter_source: -> { dropping_client }).deliver(item.id)

      expect(item.reload.delivered_at).to be_present
      # "Lost responses and a crash after prepare over committed data converge: after abort, each entry's reservation state equals its state before the save"
      expect(fake.entry_locked?(entry_id)).to eq(locked_before)
      expect(fake.reservations_for(entry_id)).to eq(reservations_before)

      # "A prepare whose answer was lost is then terminal, and a late copy cannot reserve."
      late_copy = Timekeeping::ReservationClient.new(http: fake_http).prepare(request)

      expect(late_copy.state).to eq("aborted")
      expect(fake.entry_locked?(entry_id)).to eq(locked_before)
      expect(fake.reservations_for(entry_id)).to eq(reservations_before)
    end
  end
end

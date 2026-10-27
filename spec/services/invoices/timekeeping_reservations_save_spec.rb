# frozen_string_literal: true

require "rails_helper"

# Invoice saves under the Timekeeping owner, end to end through the boundary,
# the coordinator, the remote reservation client and the outbox delivery. The
# coordinator writes the pending intent on its own connection, and the races
# need two connections, so every example runs on committed data.
RSpec.describe "Invoice saves under the Timekeeping owner", committed_data: true do
  let(:tk_save_company) { create(:company) }
  let(:tk_save_client) { create(:client, company: tk_save_company) }
  let(:tk_save_project) { create(:project, client: tk_save_client, billable: true) }
  let(:tk_save_user) { create(:user, current_workspace_id: tk_save_company.id) }
  let(:tk_save_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  before do
    TimekeepingOwnership.current.update!(owner: "timekeeping", handoff_step: nil)
    tk_save_fake.generation = TimekeepingOwnership.current.generation
  end

  # One entry in the timesheet_entries projection and on the fake, under one id.
  def tk_save_entry
    row = create(:timesheet_entry, user: tk_save_user, project: tk_save_project, bill_status: "unbilled")
    tk_save_fake.add_entry(company_id: tk_save_company.id, user_id: tk_save_user.id, project_id: tk_save_project.id,
                           id: row.id)
    row
  end

  def tk_save_invoice(number, status: :draft)
    create(:invoice, company: tk_save_company, client: tk_save_client, status:, invoice_number: number)
  end

  # The fake keeps its state in plain Ruby arrays, so two save threads reach
  # it one request at a time.
  def tk_save_serialized_http
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: tk_save_fake, relay: nil)
    mutex = Mutex.new
    http = Object.new
    http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      mutex.synchronize { fake_client.call(method, path, headers:, body:) }
    end
    http
  end

  # Holds every call of method_name on the client until the spec releases it,
  # and reports each arrival, so both saves reach that point before either
  # goes on.
  def tk_save_hold_at(client, method_name, arrived:, release:)
    real = client.method(method_name)
    client.define_singleton_method(method_name) do |request|
      arrived << request.invoice_id
      release.pop
      real.call(request)
    end
  end

  # Runs the block in its own transaction on its own connection and returns
  # the error it raised, or nil.
  def tk_save_in_thread(&block)
    committed_data_thread do
      Thread.current[:tk_save_error] = nil
      ApplicationRecord.transaction(&block)
    rescue StandardError => error
      Thread.current[:tk_save_error] = error
    end
  end

  # Releases every held save and waits for its thread, also when an
  # expectation failed while they were held, so no save keeps its
  # connection and locks while the database is cleaned.
  def tk_save_release_all(threads, release)
    threads.size.times { release << true }
    threads.each(&:join)
  end

  def tk_save_prepares
    tk_save_fake.requests.count { |request| request[:path].end_with?("/reservations/prepare") }
  end

  def tk_save_refusal_message(error)
    ErrorHandler::RESERVATION_REFUSAL_MESSAGES.fetch(error.outcome.conflicts.first.fetch(:reason))
  end

  # "two invoices racing on one entry over separate connections, with a barrier: exactly one keeps it, and the other fails with \"entry is on another invoice\";"
  it "two drafts racing on one entry over separate connections leave it on exactly one, and the other is refused as on another invoice" do
    entry = tk_save_entry
    first = tk_save_invoice("TK-RACE-1")
    second = tk_save_invoice("TK-RACE-2")
    client = use_fake_timekeeping_reservations(tk_save_fake, http: tk_save_serialized_http)
    arrived = Queue.new
    release = Queue.new
    tk_save_hold_at(client, :prepare, arrived:, release:)

    threads = [first, second].map do |invoice|
      tk_save_in_thread do
        create(:invoice_line_item, invoice: Invoice.find(invoice.id), timesheet_entry: entry, rate: 100, quantity: 60)
      end
    end
    begin
      expect([arrived.pop, arrived.pop]).to contain_exactly(first.id, second.id)
      # Both pending intents are committed before either save asks to prepare.
      expect(InvoiceOperationIntent.where(company_id: tk_save_company.id, state: "pending").pluck(:invoice_id))
        .to contain_exactly(first.id, second.id)
    ensure
      tk_save_release_all(threads, release)
    end

    errors = threads.pluck(:tk_save_error)
    winner, loser = errors.first.nil? ? [first, second] : [second, first]
    expect(errors.compact.size).to eq(1)
    refusal = errors.compact.first
    expect(refusal).to be_a(Invoices::OperationErrors::Refused)
    expect(tk_save_refusal_message(refusal)).to eq("entry is on another invoice")

    expect(tk_save_fake.reservations_for(entry.id)).to eq([{ "invoice_id" => winner.id, "state" => "committed" }])
    expect(tk_save_fake.entry_locked?(entry.id)).to be(true)
    expect(InvoiceLineItem.where(timesheet_entry_id: entry.id).pluck(:invoice_id)).to eq([winner.id])
    expect(InvoiceOperationIntent.where(company_id: tk_save_company.id, invoice_id: winner.id).pluck(:state))
      .to eq(["committed"])
    expect(InvoiceOperationIntent.where(company_id: tk_save_company.id, invoice_id: loser.id).pluck(:state))
      .to eq(["failed"])

    # Delivering the loser's abort again never takes the entry from the winner.
    RecoverInvoiceOperationIntentsJob.perform_now(reservations: client)
    expect(tk_save_fake.reservations_for(entry.id)).to eq([{ "invoice_id" => winner.id, "state" => "committed" }])
  end

  # "Lost responses, a crash after prepare and concurrent saves on separate connections over committed data converge"
  it "two sent invoices adding one entry over separate connections admit it to exactly one and reserve nothing on Timekeeping" do
    entry = tk_save_entry
    first = tk_save_invoice("TK-ADMIT-1", status: :sent)
    second = tk_save_invoice("TK-ADMIT-2", status: :sent)
    client = use_fake_timekeeping_reservations(tk_save_fake, http: tk_save_serialized_http)
    arrived = Queue.new
    release = Queue.new
    tk_save_hold_at(client, :admit, arrived:, release:)

    threads = [first, second].map do |invoice|
      tk_save_in_thread do
        create(:invoice_line_item, invoice: Invoice.find(invoice.id), timesheet_entry: entry, rate: 100, quantity: 60)
      end
    end
    begin
      expect([arrived.pop, arrived.pop]).to contain_exactly(first.id, second.id)
    ensure
      tk_save_release_all(threads, release)
    end

    errors = threads.pluck(:tk_save_error)
    expect(errors.compact.size).to eq(1)
    expect(errors.compact.first).to be_a(Invoices::OperationErrors::Refused)
    expect(tk_save_refusal_message(errors.compact.first)).to eq("entry is on another invoice")
    winner = errors.first.nil? ? first : second
    expect(InvoiceLineItem.where(timesheet_entry_id: entry.id).pluck(:invoice_id)).to eq([winner.id])
    expect(tk_save_prepares).to eq(0)
    expect(tk_save_fake.reservations_for(entry.id)).to eq([])
  end

  # "Lost responses, a crash after prepare and concurrent saves on separate connections over committed data converge"
  it "refuses a draft taking an entry a sent invoice holds only through its line, and Timekeeping gains no reservation" do
    entry = tk_save_entry
    sent = tk_save_invoice("TK-SENT-LINE", status: :sent)
    use_fake_timekeeping_reservations(tk_save_fake)
    create(:invoice_line_item, invoice: sent, timesheet_entry: entry, rate: 100, quantity: 60)
    expect(tk_save_fake.reservations_for(entry.id)).to eq([])

    draft = tk_save_invoice("TK-DRAFT-TAKER")
    expect do
      ApplicationRecord.transaction do
        create(:invoice_line_item, invoice: Invoice.find(draft.id), timesheet_entry: entry, rate: 100, quantity: 60)
      end
    end.to raise_error(Invoices::OperationErrors::Refused) { |error|
      expect(error.outcome.conflicts).to eq([{ entry_id: entry.id, reason: "on_another_invoice" }])
    }

    expect(InvoiceLineItem.where(invoice_id: draft.id)).to be_empty
    expect(InvoiceOperationIntent.where(company_id: tk_save_company.id, invoice_id: draft.id).pluck(:state))
      .to eq(["failed"])
    expect(tk_save_fake.reservations_for(entry.id)).to eq([])
    expect(tk_save_fake.entry_locked?(entry.id)).to be(false)
  end

  # "a crash between prepare and step 3 leaves the intent pending, and `RecoverInvoiceOperationIntentsJob` fails it and aborts;"
  it "a save interrupted right after Timekeeping prepared leaves a pending intent that recovery fails and aborts" do
    entry = tk_save_entry
    draft = tk_save_invoice("TK-CRASH")
    before_save = [tk_save_fake.entry_locked?(entry.id), tk_save_fake.reservations_for(entry.id)]
    # Stands in for the process dying: it is not a StandardError, so nothing
    # on the save path rescues it.
    process_died = Class.new(Exception) # rubocop:disable Lint/InheritException
    fake_client = TimekeepingContract::FakeClient.new(timekeeping: tk_save_fake, relay: nil)
    crashing_http = Object.new
    crashing_http.define_singleton_method(:call) do |method, path, headers: {}, body: nil|
      response = fake_client.call(method, path, headers:, body:)
      raise process_died if path.end_with?("/reservations/prepare")

      response
    end
    use_fake_timekeeping_reservations(tk_save_fake, http: crashing_http)
    # A dead process never runs the failure settlement after the rollback.
    allow_any_instance_of(Invoices::OperationCoordinator).to receive(:record_failure) # rubocop:disable RSpec/AnyInstance

    expect do
      ApplicationRecord.transaction do
        create(:invoice_line_item, invoice: Invoice.find(draft.id), timesheet_entry: entry, rate: 100, quantity: 60)
      end
    end.to raise_error(process_died)

    expect(InvoiceLineItem.where(invoice_id: draft.id)).to be_empty
    intent = InvoiceOperationIntent.find_by!(company_id: tk_save_company.id, invoice_id: draft.id)
    expect(intent.state).to eq("pending")
    expect(InvoiceOperationOutboxItem.where(company_id: tk_save_company.id, invoice_id: draft.id)).to be_empty
    expect(tk_save_fake.reservations_for(entry.id)).to eq([{ "invoice_id" => draft.id, "state" => "provisional" }])

    recovery_client = Timekeeping::ReservationClient.new(
      http: fake_client,
      credential: lambda do |company_id:, operation:|
        Timekeeping::ServiceToken.mint(company_id:, operations: [operation], private_key: timekeeping_key_pair)
      end
    )
    RecoverInvoiceOperationIntentsJob.perform_now(pickup_age: 0.seconds, reservations: recovery_client)

    expect(intent.reload.state).to eq("failed")
    abort_row = InvoiceOperationOutboxItem.find_by!(company_id: tk_save_company.id, invoice_id: draft.id, kind: "abort")
    expect(abort_row.delivered_at).to be_present
    expect([tk_save_fake.entry_locked?(entry.id), tk_save_fake.reservations_for(entry.id)]).to eq(before_save)
  end

  # "a step-3 guarded update matching no row rolls back the invoice change and writes no commit row;"
  it "rolls back the invoice change and writes no commit row when recovery fails the intent between prepare and step 3, and the abort frees the entry" do
    entry = tk_save_entry
    draft = tk_save_invoice("TK-GUARDED")
    client = use_fake_timekeeping_reservations(tk_save_fake)
    real_prepare = client.method(:prepare)
    # Recovery fails the intent and writes its abort row on its own
    # connection after Timekeeping prepared, before the save reaches step 3.
    client.define_singleton_method(:prepare) do |request|
      outcome = real_prepare.call(request)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          InvoiceOperationIntent.where(company_id: request.company_id, operation_id: request.operation_id, state: "pending")
            .update_all(state: "failed", finished_at: Time.current)
          InvoiceOperationOutboxItem.record!(
            kind: "abort", company_id: request.company_id, invoice_id: request.invoice_id,
            operation_id: request.operation_id, generation: request.generation,
            disposition: request.disposition, desired_entry_ids: request.entries
          )
        end
      end.join
      outcome
    end

    expect do
      ApplicationRecord.transaction do
        create(:invoice_line_item, invoice: Invoice.find(draft.id), timesheet_entry: entry, rate: 100, quantity: 60)
      end
    end.to raise_error(Invoices::OperationErrors::IntentNotPending)

    expect(InvoiceLineItem.where(invoice_id: draft.id)).to be_empty
    expect(InvoiceEntryHolding.where(company_id: tk_save_company.id, invoice_id: draft.id)).to be_empty
    expect(InvoiceOperationOutboxItem.where(company_id: tk_save_company.id, invoice_id: draft.id).pluck(:kind))
      .to eq(["abort"])
    expect(tk_save_fake.reservations_for(entry.id)).to eq([{ "invoice_id" => draft.id, "state" => "provisional" }])

    RecoverInvoiceOperationIntentsJob.perform_now(reservations: client)

    abort_row = InvoiceOperationOutboxItem.find_by!(company_id: tk_save_company.id, invoice_id: draft.id, kind: "abort")
    expect(abort_row.delivered_at).to be_present
    expect(tk_save_fake.reservations_for(entry.id)).to eq([])
    expect(tk_save_fake.entry_locked?(entry.id)).to be(false)
  end
end

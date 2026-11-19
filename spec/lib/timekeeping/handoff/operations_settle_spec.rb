# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Timekeeping::Handoff::OperationsSettle do
  include PreparedReservationsSpecSupport
  include TimekeepingLocalOwnerSpecHelpers

  # Settle specs run inside the example transaction, so the integration reads
  # on that transaction's connection rather than InvoiceOperationsRecord's own
  # pool, which could not see the uncommitted fixture rows.
  def operations_settle_spec_monolith(reservations: Invoices::PreparedReservations.new)
    connection = ActiveRecord::Base.connection
    described_class.new(owner: described_class::MonolithPort.new(connection:), reservations:, connection:)
  end

  # A prepared operation and its intent at the outgoing generation, with the
  # ownership row raised by one as close_admission leaves it.
  def operations_settle_spec_prepared(intent_state:)
    outgoing = prepare_local_ownership!.generation
    company = create(:company)
    entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    request = prepared_spec_request(company, invoice, [entry.id])
    expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
    InvoiceOperationIntent.create!(
      company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id, generation: outgoing,
      disposition: "active", desired_entry_ids: [entry.id], state: intent_state, created_at: 1.minute.ago
    )
    { outgoing:, company:, entry:, invoice:, request: }
  end

  def operations_settle_spec_commit_row(seed)
    InvoiceOperationOutboxItem.record!(
      kind: "commit", company_id: seed[:company].id, invoice_id: seed[:invoice].id,
      operation_id: seed[:request].operation_id, generation: seed[:outgoing], disposition: "active",
      desired_entry_ids: [seed[:entry].id]
    )
  end

  def operations_settle_spec_raise_generation(seed)
    TimekeepingOwnership.current.update_columns(generation: seed[:outgoing] + 1, handoff_step: "settle")
  end

  it "settle! leaves no pending intent and no prepared operation when one was prepared before close_admission" do
    seed = operations_settle_spec_prepared(intent_state: "pending")
    operations_settle_spec_raise_generation(seed)
    settle = operations_settle_spec_monolith

    # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
    expect(settle.settled?).to be(false)

    settle.settle!(generation: seed[:outgoing] + 1)

    # "`settle!` leaves no 'pending' intent and no 'prepared' operation when one was prepared before close_admission."
    expect(InvoiceOperationIntent.where(state: "pending")).not_to exist
    expect(prepared_spec_operations(seed[:company], seed[:invoice]).map(&:first)).not_to include("prepared")
    expect(settle.settled?).to be(true)
  end

  it "settled? is false while an intent is pending even when no operation is prepared" do
    generation = prepare_local_ownership!.generation
    company = create(:company)
    invoice = prepared_spec_invoice(company)
    InvoiceOperationIntent.create!(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid, generation:,
      disposition: "active", desired_entry_ids: [], state: "pending", created_at: 1.minute.ago
    )

    expect(described_class::MonolithPort.new(connection: ActiveRecord::Base.connection).prepared_operations).to eq(0)
    # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
    expect(operations_settle_spec_monolith.settled?).to be(false)
  end

  it "a row marked undeliverable by stale_generation is redelivered and resolved, and a repeated settle! applies its commit once" do
    seed = operations_settle_spec_prepared(intent_state: "committed")
    row_id = operations_settle_spec_commit_row(seed)
    InvoiceOperationOutboxItem.where(id: row_id).update_all(undeliverable_at: Time.current)
    operations_settle_spec_raise_generation(seed)

    commit_calls = []
    applied_commits = []
    prepared = Invoices::PreparedReservations.new
    reservations = Object.new
    reservations.define_singleton_method(:prepare) { |req| prepared.prepare(req) }
    reservations.define_singleton_method(:abort) { |req| prepared.abort(req) }
    reservations.define_singleton_method(:commit) do |req|
      commit_calls << req.operation_id
      outcome = prepared.commit(req)
      applied_commits << req.operation_id if outcome&.state == "committed"
      outcome
    end
    settle = operations_settle_spec_monolith(reservations:)
    operation_id = seed[:request].operation_id

    # "A row marked undeliverable by stale_generation is redelivered and resolved."
    # A settle! that delivers without clearing the mark leaves this row skipped and the operation prepared.
    settle.settle!(generation: seed[:outgoing] + 1)
    row = InvoiceOperationOutboxItem.find(row_id)
    expect(row.delivered_at).to be_present
    expect(row.undeliverable_at).to be_nil
    expect(commit_calls).to eq([operation_id])
    expect(prepared_spec_operations(seed[:company], seed[:invoice]).map(&:first)).to eq(["committed"])
    delivered_at = row.delivered_at
    attempts = row.attempts

    # "A repeated `settle!` applies no commit twice."
    settle.settle!(generation: seed[:outgoing] + 1)
    expect(applied_commits).to eq([operation_id])
    expect(commit_calls).to eq([operation_id])
    expect(InvoiceOperationOutboxItem.find(row_id)).to have_attributes(delivered_at:, attempts:)
    expect(InvoiceOperationOutboxItem.where(company_id: seed[:company].id, operation_id:).count).to eq(1)
    expect(prepared_spec_operations(seed[:company], seed[:invoice]).map(&:first)).to eq(["committed"])
    expect(settle.settled?).to be(true)
  end

  it "a repeated settle! applies a committed intent's commit once across both runs" do
    seed = operations_settle_spec_prepared(intent_state: "committed")
    row_id = operations_settle_spec_commit_row(seed)
    operations_settle_spec_raise_generation(seed)
    company = seed[:company]
    invoice = seed[:invoice]

    calls = []
    inner = Invoices::PreparedReservations.new
    reservations = Object.new
    reservations.define_singleton_method(:commit) { |req| calls << [:commit, req.operation_id]; inner.commit(req) }
    reservations.define_singleton_method(:abort) { |req| calls << [:abort, req.operation_id]; inner.abort(req) }
    settle = operations_settle_spec_monolith(reservations:)

    settle.settle!(generation: seed[:outgoing] + 1)
    after_first = [prepared_spec_operations(company, invoice), prepared_spec_reservations(company),
                   InvoiceOperationOutboxItem.find(row_id).delivered_at]
    settle.settle!(generation: seed[:outgoing] + 1)

    # "A repeated `settle!` applies no commit twice."
    expect(calls).to eq([[:commit, seed[:request].operation_id]])
    expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
    expect([prepared_spec_operations(company, invoice), prepared_spec_reservations(company),
            InvoiceOperationOutboxItem.find(row_id).delivered_at]).to eq(after_first)
    expect(settle.settled?).to be(true)
  end

  it "stop_applying! on a fresh instance after settle!(generation: 5) stops 4 and never the raised generation" do
    prepare_local_ownership!
    TimekeepingOwnership.current.update_columns(generation: 5, handoff_step: "settle")

    operations_settle_spec_monolith.settle!(generation: 5)
    # "`settle!(generation: 5)` begins settling at 4."
    expect(TimekeepingOwnership.current.settling_generation).to eq(4)

    # A restarted runner holds no generation in memory.
    operations_settle_spec_monolith.stop_applying!

    # "It reads the raised generation from the stored `timekeeping_ownership` row and stops that generation minus one, so a restarted runner gets the same answer."
    ownership = TimekeepingOwnership.current
    expect(ownership.settling_stopped_generation).to eq(4)
    expect(ownership.settling_generation).to be_nil
    expect(ownership.generation).to eq(5)
  end

  it "settle! with no open handoff raises NotSettling and leaves an undeliverable row marked" do
    seed = operations_settle_spec_prepared(intent_state: "committed")
    row_id = operations_settle_spec_commit_row(seed)
    InvoiceOperationOutboxItem.where(id: row_id).update_all(undeliverable_at: Time.current)
    # The generation is raised but no handoff step is recorded, so begin_settling! opens nothing.
    TimekeepingOwnership.current.update_columns(generation: seed[:outgoing] + 1, handoff_step: nil)
    settle = operations_settle_spec_monolith

    # Clearing the mark before settling opens would only have the owner refuse the row as stale again.
    expect { settle.settle!(generation: seed[:outgoing] + 1) }.to raise_error(described_class::NotSettling)
    row = InvoiceOperationOutboxItem.find(row_id)
    expect(row.undeliverable_at).to be_present
    expect(row.delivered_at).to be_nil
    expect(prepared_spec_operations(seed[:company], seed[:invoice]).map(&:first)).to eq(["prepared"])
  end

  it "settle! keeps the undeliverable mark on a row whose intent belongs to an older generation" do
    g = prepare_local_ownership!.generation
    company = create(:company)
    invoice = prepared_spec_invoice(company)
    operation_id = SecureRandom.uuid
    InvoiceOperationIntent.create!(company_id: company.id, invoice_id: invoice.id, operation_id:,
                                   generation: g, disposition: "active", desired_entry_ids: [],
                                   state: "committed", created_at: 1.minute.ago)
    row_id = InvoiceOperationOutboxItem.record!(kind: "commit", company_id: company.id, invoice_id: invoice.id,
                                                operation_id:, generation: g, disposition: "active",
                                                desired_entry_ids: [])
    InvoiceOperationOutboxItem.where(id: row_id).update_all(undeliverable_at: Time.current)
    # Two generations above the row's intent, so the row is not the outgoing generation's.
    TimekeepingOwnership.current.update_columns(generation: g + 2, handoff_step: "settle")

    operations_settle_spec_monolith.settle!(generation: g + 2)

    row = InvoiceOperationOutboxItem.find(row_id)
    expect(row.undeliverable_at).to be_present
    expect(row.delivered_at).to be_nil
  end

  describe described_class::MonolithPort do
    # "Settle ends only when no intent is 'pending' and no operation is 'prepared'"
    it "the monolith port counts a prepared operation, so settle is not done until that operation leaves 'prepared'" do
      g = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      adapter = Invoices::PreparedReservations.new
      expect(adapter.prepare(request).state).to eq("prepared")
      TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: "settle")

      port = described_class.new(connection: ActiveRecord::Base.connection)
      settle = Timekeeping::Handoff::OperationsSettle.new(
        owner: port, reservations: adapter, connection: ActiveRecord::Base.connection
      )

      expect(port.begin_settling(generation: g)).to be(true)
      expect(port.prepared_operations).to eq(1)
      # No intent is pending here, so only the prepared operation keeps settle open.
      expect(settle.settled?).to be(false)

      expect(adapter.abort(request).state).to eq("aborted")

      expect(port.prepared_operations).to eq(0)
      expect(settle.settled?).to be(true)
    end
  end

  describe described_class::TimekeepingPort do
    # "Settle begins settling at that generation minus one, the outgoing one, and never accepts the raised generation."
    it "settle! through the Timekeeping port asks Timekeeping to settle generation 4 when given the raised generation 5, never 5" do
      store = instance_double(Timekeeping::Handoff::TimekeepingStore)
      allow(store).to receive(:settle).and_return(
        Timekeeping::Handoff::TimekeepingStore::SettleAnswer.new(settling: true, prepared_operations: 0)
      )
      settle = Timekeeping::Handoff::OperationsSettle.new(
        owner: described_class.new(store:), reservations: double("reservations"),
        connection: ActiveRecord::Base.connection
      )

      settle.settle!(generation: 5)

      expect(store).to have_received(:settle).with(generation: 4).at_least(:once)
      expect(store).not_to have_received(:settle).with(generation: 5)
    end

    it "the Timekeeping port is not settled while Timekeeping reports a prepared operation, and stops the raised generation minus one" do
      TimekeepingOwnership.current.update_columns(generation: 5, handoff_step: "settle")
      store = instance_double(Timekeeping::Handoff::TimekeepingStore)
      allow(store).to receive(:settle).and_return(
        Timekeeping::Handoff::TimekeepingStore::SettleAnswer.new(settling: true, prepared_operations: 1)
      )
      allow(store).to receive(:stop_applying).and_return(nil)
      settle = Timekeeping::Handoff::OperationsSettle.new(owner: described_class.new(store:),
                                                          reservations: Object.new,
                                                          connection: ActiveRecord::Base.connection)

      expect(InvoiceOperationIntent.where(state: "pending")).not_to exist
      # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
      expect(settle.settled?).to be(false)

      settle.stop_applying!
      expect(store).to have_received(:stop_applying).with(generation: 4)
      expect(store).not_to have_received(:stop_applying).with(generation: 5)
    end
  end
end

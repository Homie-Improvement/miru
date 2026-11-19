# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Invoices::PreparedReservations, "settle step" do
  include PreparedReservationsSpecSupport

  def prepared_settling_spec_open(outgoing)
    TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
    TimekeepingOwnership.begin_settling!(generation: outgoing)
  end

  it "applies a settling commit once and refuses the identical request as stale after stop_applying!, on every retry, with nothing stored" do
    prepare_local_ownership!
    company = create(:company)
    entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    adapter = described_class.new
    outgoing = TimekeepingOwnership.current.generation
    request = prepared_spec_request(company, invoice, [entry.id])
    expect(adapter.prepare(request).state).to eq("prepared")

    prepared_settling_spec_open(outgoing)

    # "a commit of a prepared operation at the outgoing generation is applied."
    expect(adapter.commit(request).state).to eq("committed")
    expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
    expect(prepared_spec_reservations(company)).to eq([[entry.id, invoice.id, "committed", "active"]])

    TimekeepingOwnership.stop_applying!(generation: outgoing)
    stored = lambda do
      [prepared_spec_operations(company, invoice), prepared_spec_reservations(company),
       prepared_spec_outbox_count(entry), entry.reload.attributes]
    end
    before = stored.call

    # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
    # "Everything else is refused as stale, with no stored change. In `PreparedReservations`, check this before
    # `finish` answers for an already-finished operation."
    2.times do
      outcome = adapter.commit(request)
      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
      expect(stored.call).to eq(before)
    end
  end

  it "prepared adapter applies an abort of a prepared operation at the outgoing generation while settling" do
    prepare_local_ownership!
    company = create(:company)
    entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    request = prepared_spec_request(company, invoice, [entry.id])
    adapter = described_class.new
    adapter.prepare(request)
    prepared_settling_spec_open(request.generation)

    # "While settling, the monolith applies a commit or abort of an operation it registered at the outgoing generation, through both LocalOwner::ReservationOperations and Invoices::PreparedReservations, and refuses prepares"
    outcome = adapter.abort(request)

    expect(outcome.state).to eq("aborted")
    expect(outcome.reason).to be_nil
    expect(prepared_spec_reservations(company)).to eq([])
  end

  it "while settling, a prepared-store commit naming another company's registered operation id is refused as stale and changes nothing of that company" do
    outgoing = prepare_local_ownership!.generation
    adapter = described_class.new
    company_a = create(:company)
    company_b = create(:company)
    entry_a = prepared_spec_entry(company_a)
    entry_b = prepared_spec_entry(company_b)
    invoice_a = prepared_spec_invoice(company_a)
    invoice_b = prepared_spec_invoice(company_b)
    operation_id = SecureRandom.uuid
    request_b = prepared_spec_request(company_b, invoice_b, [entry_b.id], operation_id:)
    request_a = prepared_spec_request(company_a, invoice_a, [entry_a.id], operation_id:)
    expect(request_a.generation).to eq(outgoing)
    expect(adapter.prepare(request_b).state).to eq("prepared")

    prepared_settling_spec_open(outgoing)
    operations_b_before = prepared_spec_operations(company_b, invoice_b)
    reservations_b_before = prepared_spec_reservations(company_b)
    outbox_b_before = prepared_spec_outbox_count(entry_b)
    entry_b_before = entry_b.reload.attributes

    # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort;
    # it carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations,
    # found by company, actor and operation id, stored at that generation."
    # "Everything else is refused as stale, with no stored change."
    foreign = adapter.commit(request_a)

    expect(foreign.state).not_to eq("committed")
    expect(foreign.reason).to eq("stale_generation")
    expect(prepared_spec_operations(company_b, invoice_b)).to eq(operations_b_before)
    expect(prepared_spec_operations(company_b, invoice_b).map(&:first)).to eq(["prepared"])
    expect(prepared_spec_reservations(company_b)).to eq(reservations_b_before)
    expect(prepared_spec_outbox_count(entry_b)).to eq(outbox_b_before)
    expect(entry_b.reload.attributes).to eq(entry_b_before)
    expect(prepared_spec_operations(company_a, invoice_a)).to be_empty
    expect(prepared_spec_reservations(company_a)).to be_empty

    # The owning company's own commit is applied, so the refusal above comes from the company
    # boundary and not from a settle step that admits nothing.
    expect(adapter.commit(request_b).state).to eq("committed")
    expect(prepared_spec_operations(company_b, invoice_b).map(&:first)).to eq(["committed"])
  end

  it "prepared adapter refuses a direct prepare, an unknown operation and an older-generation operation while settling" do
    prepare_local_ownership!
    company = create(:company)
    entry = prepared_spec_entry(company)
    other_entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    other_invoice = prepared_spec_invoice(company)
    old_request = prepared_spec_request(company, invoice, [entry.id])
    adapter = described_class.new
    adapter.prepare(old_request)

    outgoing = old_request.generation + 1
    prepared_settling_spec_open(outgoing)
    at_outgoing = lambda do |target_invoice, entries, operation_id|
      Invoices::ReservationRequest.new(company_id: company.id, invoice_id: target_invoice.id, operation_id:,
                                       generation: outgoing, disposition: "active", entries:)
    end
    reservations_before = prepared_spec_reservations(company)
    outbox_before = prepared_spec_outbox_count(other_entry)
    version_before = other_entry.reload.version

    # "A new prepare ... and a commit for an unknown operation are refused." A commit for an operation stored at an older generation is refused too.
    outcomes = [
      adapter.prepare(at_outgoing.call(other_invoice, [other_entry.id], SecureRandom.uuid)),
      adapter.commit(at_outgoing.call(invoice, [entry.id], SecureRandom.uuid)),
      adapter.commit(at_outgoing.call(invoice, [entry.id], old_request.operation_id))
    ]

    outcomes.each do |outcome|
      expect(outcome.state).not_to eq("prepared")
      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
    end
    expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["prepared"])
    expect(prepared_spec_operations(company, other_invoice)).to eq([])
    expect(prepared_spec_reservations(company)).to eq(reservations_before)
    expect(prepared_spec_outbox_count(other_entry)).to eq(outbox_before)
    expect(other_entry.reload.version).to eq(version_before)
  end

  it "refuses a prepared-adapter settling commit whose request generation is one below the settling generation" do
    prepare_local_ownership!
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(generation: 3)
    company = create(:company)
    invoice = prepared_spec_invoice(company)
    entry = prepared_spec_entry(company)
    request = prepared_spec_request(company, invoice, [entry.id])
    adapter = described_class.new
    expect(adapter.prepare(request).state).to eq("prepared")
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(generation: 4, handoff_step: "settle")
    TimekeepingOwnership.begin_settling!(generation: 3)
    older = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id,
      generation: 2, disposition: request.disposition, entries: request.entries
    )
    reservations_before = prepared_spec_reservations(company)
    version_before = entry.reload.version
    outbox_before = prepared_spec_outbox_count(entry)

    # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort;
    # it carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations,
    # found by company, actor and operation id, stored at that generation."
    outcome = adapter.commit(older)

    expect(outcome.state).to eq("retryable")
    expect(outcome.reason).to eq("stale_generation")
    expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["prepared"])
    expect(prepared_spec_reservations(company)).to eq(reservations_before)
    expect(entry.reload.version).to eq(version_before)
    expect(prepared_spec_outbox_count(entry)).to eq(outbox_before)
  end

  it "refuses admit and mark_billed called directly on the adapter while settling, writing nothing" do
    outgoing = prepare_local_ownership!.generation
    company = create(:company)
    entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    prepared_settling_spec_open(outgoing)
    request = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
      generation: outgoing, disposition: "active", entries: [entry.id]
    )
    entry_before = entry.reload.attributes
    outbox_before = prepared_spec_outbox_count(entry)

    outcomes = [described_class.new.admit(request), described_class.new.mark_billed(request)]

    expect(outcomes.map { |outcome| [outcome.state, outcome.reason] })
      .to eq([%w[retryable stale_generation], %w[retryable stale_generation]])
    expect(entry.reload.attributes).to eq(entry_before)
    expect(prepared_spec_outbox_count(entry)).to eq(outbox_before)
    expect(prepared_spec_operations(company, invoice)).to eq([])
  end

  it "still applies a commit while only the admission fence mark is set" do
    prepare_local_ownership!
    company = create(:company)
    entry = prepared_spec_entry(company)
    invoice = prepared_spec_invoice(company)
    request = prepared_spec_request(company, invoice, [entry.id])
    adapter = described_class.new
    expect(adapter.prepare(request).state).to eq("prepared")
    TimekeepingOwnership.current.update_columns(admission_fenced_at: Time.current)

    expect(adapter.commit(request).state).to eq("committed")
    expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
  end
end

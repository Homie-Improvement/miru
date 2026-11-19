# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Invoices::PreparedReservations do
  context "more tests 10", "settling across companies" do
    include PreparedReservationsSpecSupport

    it "refuses a settling commit that carries another company's registered operation id as stale and leaves that company's operation prepared" do
      outgoing = prepare_local_ownership!.generation
      adapter = described_class.new
      owning_company = create(:company)
      other_company = create(:company)
      owning_invoice = prepared_spec_invoice(owning_company)
      other_invoice = prepared_spec_invoice(other_company)
      entry = prepared_spec_entry(owning_company)
      operation_id = SecureRandom.uuid
      owning_request = prepared_spec_request(owning_company, owning_invoice, [entry.id], operation_id:)
      expect(adapter.prepare(owning_request).state).to eq("prepared")

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      reservations_before = prepared_spec_reservations(owning_company)
      outbox_before = prepared_spec_outbox_count(entry)
      version_before = entry.reload.version

      foreign_request = Invoices::ReservationRequest.new(
        company_id: other_company.id, invoice_id: other_invoice.id, operation_id:, generation: outgoing,
        disposition: "active", entries: [entry.id]
      )

      # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort; it
      # carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations, found by
      # company, actor and operation id, stored at that generation."
      # "Everything else is refused as stale, with no stored change."
      outcome = adapter.commit(foreign_request)

      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
      expect(prepared_spec_operations(owning_company, owning_invoice).map(&:first)).to eq(["prepared"])
      expect(prepared_spec_operations(other_company, other_invoice)).to be_empty
      expect(prepared_spec_reservations(owning_company)).to eq(reservations_before)
      expect(prepared_spec_outbox_count(entry)).to eq(outbox_before)
      expect(entry.reload.version).to eq(version_before)
    end
  end

  context "more tests 11" do
    include PreparedReservationsSpecSupport

    it "applies a settling commit once and refuses the identical request as stale after stop_applying!, on every retry, with nothing stored" do
      prepare_local_ownership!
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      adapter = described_class.new
      outgoing = TimekeepingOwnership.current.generation
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(adapter.prepare(request).state).to eq("prepared")

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)

      # "a commit of a prepared operation at the outgoing generation is applied."
      expect(adapter.commit(request).state).to eq("committed")
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])

      TimekeepingOwnership.stop_applying!(generation: outgoing)
      stored = lambda do
        [prepared_spec_operations(company, invoice), prepared_spec_reservations(company),
         prepared_spec_outbox_count(entry), entry.reload.version]
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
  end

  context "more tests 12" do
    include PreparedReservationsSpecSupport

    it "refuses a new prepare while settling and stores no operation, reservation or snapshot" do
      prepare_local_ownership!
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      outgoing = TimekeepingOwnership.current.generation
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      request = Invoices::ReservationRequest.new(
        company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
        generation: outgoing, disposition: "active", entries: [entry.id]
      )
      version = entry.reload.version
      outbox = prepared_spec_outbox_count(entry)

      # "While settling, the monolith applies a commit or abort of an operation it registered at the outgoing
      # generation, through both LocalOwner::ReservationOperations and Invoices::PreparedReservations, and refuses prepares"
      outcome = described_class.new.prepare(request)

      expect(outcome.state).not_to eq("prepared")
      expect(outcome.reason).to eq("stale_generation")
      expect(prepared_spec_operations(company, invoice)).to eq([])
      expect(prepared_spec_reservations(company)).to eq([])
      expect(prepared_spec_outbox_count(entry)).to eq(outbox)
      expect(entry.reload.version).to eq(version)
    end
  end

  context "more tests 13", "settling across companies" do
    include PreparedReservationsSpecSupport

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

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
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
  end

  context "more tests 14", "settling commit applied" do
    include PreparedReservationsSpecSupport

    it "prepared adapter applies a commit of a prepared operation at the outgoing generation while settling" do
      prepare_local_ownership!
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      adapter = described_class.new
      expect(adapter.prepare(request).state).to eq("prepared")

      outgoing = request.generation
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)

      # "a commit of a prepared operation at the outgoing generation is applied."
      outcome = adapter.commit(request)

      expect(outcome.state).to eq("committed")
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
      expect(prepared_spec_reservations(company)).to eq([[entry.id, invoice.id, "committed", "active"]])
    end
  end

  context "more tests 15", "settling commit after stop" do
    include PreparedReservationsSpecSupport

    it "prepared adapter refuses the same commit as stale after stop_applying! instead of answering committed" do
      prepare_local_ownership!
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      adapter = described_class.new
      adapter.prepare(request)
      outgoing = request.generation
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      expect(adapter.commit(request).state).to eq("committed")

      TimekeepingOwnership.stop_applying!(generation: outgoing)
      operations_before = prepared_spec_operations(company, invoice)
      reservations_before = prepared_spec_reservations(company)
      entry_before = entry.reload.attributes
      outbox_before = prepared_spec_outbox_count(entry)

      # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
      # "In `PreparedReservations`, check this before `finish` answers for an already-finished operation."
      outcome = adapter.commit(request)

      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
      expect(prepared_spec_operations(company, invoice)).to eq(operations_before)
      expect(prepared_spec_reservations(company)).to eq(reservations_before)
      expect(entry.reload.attributes).to eq(entry_before)
      expect(prepared_spec_outbox_count(entry)).to eq(outbox_before)
    end
  end

  context "more tests 16", "settling refusals" do
    include PreparedReservationsSpecSupport

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
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      at_outgoing = lambda do |target_invoice, entries, operation_id|
        Invoices::ReservationRequest.new(company_id: company.id, invoice_id: target_invoice.id, operation_id:,
                                         generation: outgoing, disposition: "active", entries:)
      end
      operations_before = prepared_spec_operations(company, invoice)
      reservations_before = prepared_spec_reservations(company)
      outbox_before = prepared_spec_outbox_count(other_entry)

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
      expect(prepared_spec_operations(company, invoice)).to eq(operations_before)
      expect(prepared_spec_operations(company, other_invoice)).to eq([])
      expect(prepared_spec_reservations(company)).to eq(reservations_before)
      expect(prepared_spec_outbox_count(other_entry)).to eq(outbox_before)
    end
  end

  context "more tests 17", "settling abort applied" do
    include PreparedReservationsSpecSupport

    it "prepared adapter applies an abort of a prepared operation at the outgoing generation while settling" do
      prepare_local_ownership!
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      adapter = described_class.new
      adapter.prepare(request)
      outgoing = request.generation
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)

      # "While settling, the monolith applies a commit or abort of an operation it registered at the outgoing generation, through both LocalOwner::ReservationOperations and Invoices::PreparedReservations, and refuses prepares"
      outcome = adapter.abort(request)

      expect(outcome.state).to eq("aborted")
      expect(outcome.reason).to be_nil
      expect(prepared_spec_reservations(company)).to eq([])
    end
  end

  context "more tests 18" do
    include PreparedReservationsSpecSupport

    it "refuses the identical commit re-delivered after stop_applying! as stale instead of answering committed" do
      prepare_local_ownership!
      outgoing = TimekeepingOwnership.current.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      adapter = described_class.new
      expect(adapter.prepare(request).state).to eq("prepared")

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      expect(adapter.commit(request).state).to eq("committed")

      TimekeepingOwnership.stop_applying!(generation: outgoing)
      operations_before = prepared_spec_operations(company, invoice)
      reservations_before = prepared_spec_reservations(company)
      outbox_before = prepared_spec_outbox_count(entry)
      version_before = entry.reload.version

      # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
      # "In `PreparedReservations`, check this before `finish` answers for an already-finished operation."
      outcome = adapter.commit(request)

      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
      # "Everything else is refused as stale, with no stored change."
      expect(prepared_spec_operations(company, invoice)).to eq(operations_before)
      expect(prepared_spec_reservations(company)).to eq(reservations_before)
      expect(prepared_spec_outbox_count(entry)).to eq(outbox_before)
      expect(entry.reload.version).to eq(version_before)
    end
  end

  context "more tests 19" do
    include PreparedReservationsSpecSupport

    it "refuses a settling-generation commit for an operation stored at an older generation and leaves it prepared" do
      prepare_local_ownership!
      TimekeepingOwnership.current.update_columns(generation: 2)
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      operation_id = SecureRandom.uuid
      older = prepared_spec_request(company, invoice, [entry.id], operation_id:)
      adapter = described_class.new
      expect(adapter.prepare(older).state).to eq("prepared")

      TimekeepingOwnership.current.update_columns(generation: 4, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: 3)
      at_settling = Invoices::ReservationRequest.new(
        company_id: company.id, invoice_id: invoice.id, operation_id:, generation: 3,
        disposition: "active", entries: [entry.id]
      )
      reservations_before = prepared_spec_reservations(company)
      outbox_before = prepared_spec_outbox_count(entry)

      # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort;
      # it carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations,
      # found by company, actor and operation id, stored at that generation."
      outcome = adapter.commit(at_settling)

      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["prepared"])
      expect(prepared_spec_reservations(company)).to eq(reservations_before)
      expect(prepared_spec_outbox_count(entry)).to eq(outbox_before)
    end
  end

  context "more tests 20" do
    include PreparedReservationsSpecSupport

    it "refuses a settling commit that names another company's operation id and leaves that company's operation prepared" do
      prepare_local_ownership!
      outgoing = TimekeepingOwnership.current.generation
      owner_company = create(:company)
      other_company = create(:company)
      owner_entry = prepared_spec_entry(owner_company)
      owner_invoice = prepared_spec_invoice(owner_company)
      other_invoice = prepared_spec_invoice(other_company)
      operation_id = SecureRandom.uuid
      adapter = described_class.new
      expect(adapter.prepare(prepared_spec_request(owner_company, owner_invoice, [owner_entry.id], operation_id:)).state)
        .to eq("prepared")

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      forged = Invoices::ReservationRequest.new(
        company_id: other_company.id, invoice_id: other_invoice.id, operation_id:, generation: outgoing,
        disposition: "active", entries: []
      )
      reservations_before = prepared_spec_reservations(owner_company)

      # "the operation exists in the monolith's invoice_operations, found by company, actor and operation id,
      # stored at that generation." "Everything else is refused as stale, with no stored change."
      outcome = adapter.commit(forged)

      expect(outcome.state).not_to eq("committed")
      expect(outcome.reason).to eq("stale_generation")
      expect(prepared_spec_operations(owner_company, owner_invoice).map(&:first)).to eq(["prepared"])
      expect(prepared_spec_operations(other_company, other_invoice)).to be_empty
      expect(prepared_spec_reservations(owner_company)).to eq(reservations_before)
    end
  end

  context "more tests 21", "settle step with an older request generation" do
    include PreparedReservationsSpecSupport

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
  end

  context "settle step admit and mark_billed" do
    include PreparedReservationsSpecSupport

    it "refuses admit and mark_billed called directly on the adapter while settling, writing nothing" do
      outgoing = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
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
  end

  context "settle step before a handoff step is recorded" do
    include PreparedReservationsSpecSupport

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
end

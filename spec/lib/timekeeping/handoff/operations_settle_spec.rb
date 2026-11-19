# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Timekeeping::Handoff::OperationsSettle do
  context "more tests 10" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "settle! leaves no pending intent and no prepared operation when one was prepared before close_admission" do
      g = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
      InvoiceOperationIntent.create!(
        company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id, generation: g,
        disposition: "active", desired_entry_ids: [entry.id], state: "pending", created_at: 1.minute.ago
      )
      TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: "settle")
      connection = ActiveRecord::Base.connection
      settle = described_class.new(
        owner: described_class::MonolithPort.new(connection:),
        reservations: Invoices::PreparedReservations.new,
        connection:
      )

      # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
      expect(settle.settled?).to be(false)

      settle.settle!(generation: g + 1)

      # "`settle!` leaves no 'pending' intent and no 'prepared' operation when one was prepared before close_admission."
      expect(settle.settled?).to be(true)
      expect(InvoiceOperationIntent.where(state: "pending")).to be_empty
      expect(prepared_spec_operations(company, invoice).map(&:first)).not_to include("prepared")
    end
  end

  context "more tests 11" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "a row marked undeliverable by stale_generation is redelivered and resolved, and a repeated settle! applies no commit twice" do
      g = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
      InvoiceOperationIntent.create!(
        company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id, generation: g,
        disposition: "active", desired_entry_ids: [entry.id], state: "committed", created_at: 1.minute.ago
      )
      id = InvoiceOperationOutboxItem.record!(
        kind: "commit", company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id,
        generation: g, disposition: "active", desired_entry_ids: [entry.id]
      )
      InvoiceOperationOutboxItem.where(id:).update_all(undeliverable_at: Time.current)
      TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: "settle")

      applied_commits = []
      prepared = Invoices::PreparedReservations.new
      recording = Object.new
      recording.define_singleton_method(:prepare) { |req| prepared.prepare(req) }
      recording.define_singleton_method(:abort) { |req| prepared.abort(req) }
      recording.define_singleton_method(:commit) do |req|
        outcome = prepared.commit(req)
        applied_commits << req.operation_id if outcome&.state == "committed"
        outcome
      end
      connection = ActiveRecord::Base.connection
      settle = described_class.new(
        owner: described_class::MonolithPort.new(connection:), reservations: recording, connection:
      )

      settle.settle!(generation: g + 1)

      # "A row marked undeliverable by stale_generation is redelivered and resolved."
      row = InvoiceOperationOutboxItem.find(id)
      expect(row.delivered_at).to be_present
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
      delivered_at = row.delivered_at

      settle.settle!(generation: g + 1)

      # "A repeated `settle!` applies no commit twice."
      expect(applied_commits).to eq([request.operation_id])
      expect(InvoiceOperationOutboxItem.find(id).delivered_at).to eq(delivered_at)
      expect(InvoiceOperationOutboxItem.where(company_id: company.id, operation_id: request.operation_id).count).to eq(1)
      expect(settle.settled?).to be(true)
    end
  end

  context "more tests 12" do
    include TimekeepingLocalOwnerSpecHelpers

    it "settle!(generation: 5) begins settling at 4 and stop_applying! on a fresh instance stops 4" do
      prepare_local_ownership!
      TimekeepingOwnership.current.update_columns(generation: 5, handoff_step: "settle")
      connection = ActiveRecord::Base.connection
      build = lambda do
        described_class.new(
          owner: described_class::MonolithPort.new(connection:),
          reservations: Invoices::PreparedReservations.new,
          connection:
        )
      end

      build.call.settle!(generation: 5)

      # "Settle begins settling at that generation minus one, the outgoing one, and never accepts the raised generation."
      expect(TimekeepingOwnership.current.settling_generation).to eq(4)

      # "It reads the raised generation from the stored `timekeeping_ownership` row and stops that generation minus one, so a restarted runner gets the same answer."
      build.call.stop_applying!

      ownership = TimekeepingOwnership.current
      expect(ownership.settling_generation).to be_nil
      expect(ownership.settling_stopped_generation).to eq(4)
    end
  end

  context "more tests 13" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "settle! leaves no pending intent and no prepared operation when one was prepared before close_admission" do
      outgoing = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
      InvoiceOperationIntent.create!(
        company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id, generation: outgoing,
        disposition: "active", desired_entry_ids: [entry.id], state: "pending", created_at: 1.minute.ago
      )
      # close_admission raises the generation and records the handoff step.
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      connection = ActiveRecord::Base.connection
      settle = described_class.new(
        owner: described_class::MonolithPort.new(connection:),
        reservations: Invoices::PreparedReservations.new,
        connection:
      )

      # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
      expect(settle.settled?).to be(false)

      settle.settle!(generation: outgoing + 1)

      # "`settle!` leaves no 'pending' intent and no 'prepared' operation when one was prepared before close_admission."
      expect(InvoiceOperationIntent.where(state: "pending")).not_to exist
      expect(prepared_spec_operations(company, invoice).map(&:first)).not_to include("prepared")
      expect(settle.settled?).to be(true)
    end
  end

  context "more tests 14" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "settled? is false while an intent is pending even when no operation is prepared" do
      generation = prepare_local_ownership!.generation
      company = create(:company)
      invoice = prepared_spec_invoice(company)
      InvoiceOperationIntent.create!(
        company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid, generation:,
        disposition: "active", desired_entry_ids: [], state: "pending", created_at: 1.minute.ago
      )
      connection = ActiveRecord::Base.connection
      settle = described_class.new(
        owner: described_class::MonolithPort.new(connection:),
        reservations: Invoices::PreparedReservations.new,
        connection:
      )

      expect(described_class::MonolithPort.new(connection:).prepared_operations).to eq(0)
      # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
      expect(settle.settled?).to be(false)
    end
  end

  context "more tests 15" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "a row marked undeliverable by stale_generation is redelivered and resolved, and a repeated settle! applies its commit once" do
      outgoing = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
      InvoiceOperationIntent.create!(
        company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id, generation: outgoing,
        disposition: "active", desired_entry_ids: [entry.id], state: "committed", created_at: 1.minute.ago
      )
      row_id = InvoiceOperationOutboxItem.record!(
        kind: "commit", company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id,
        generation: outgoing, disposition: "active", desired_entry_ids: [entry.id]
      )
      InvoiceOperationOutboxItem.where(id: row_id).update_all(undeliverable_at: Time.current)
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")

      applied_commits = []
      prepared = Invoices::PreparedReservations.new
      reservations = Object.new
      reservations.define_singleton_method(:prepare) { |req| prepared.prepare(req) }
      reservations.define_singleton_method(:abort) { |req| prepared.abort(req) }
      reservations.define_singleton_method(:commit) do |req|
        outcome = prepared.commit(req)
        applied_commits << req.operation_id if outcome&.state == "committed"
        outcome
      end
      connection = ActiveRecord::Base.connection
      settle = described_class.new(owner: described_class::MonolithPort.new(connection:), reservations:, connection:)

      # "A row marked undeliverable by stale_generation is redelivered and resolved."
      settle.settle!(generation: outgoing + 1)
      row = InvoiceOperationOutboxItem.find(row_id)
      expect(row.delivered_at).to be_present
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
      delivered_at = row.delivered_at
      attempts = row.attempts

      # "A repeated `settle!` applies no commit twice."
      settle.settle!(generation: outgoing + 1)
      expect(applied_commits).to eq([request.operation_id])
      expect(InvoiceOperationOutboxItem.find(row_id)).to have_attributes(delivered_at:, attempts:)
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
      expect(settle.settled?).to be(true)
    end
  end

  context "more tests 16" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "settle!(generation: 5) begins settling at 4 and stop_applying! on a fresh instance stops 4" do
      prepare_local_ownership!
      TimekeepingOwnership.current.update_columns(generation: 5, handoff_step: "settle")
      connection = ActiveRecord::Base.connection
      build = lambda do
        described_class.new(owner: described_class::MonolithPort.new(connection:),
                            reservations: Invoices::PreparedReservations.new, connection:)
      end

      # "`settle!(generation: 5)` begins settling at 4."
      build.call.settle!(generation: 5)
      expect(TimekeepingOwnership.current.reload.settling_generation).to eq(4)

      # "It reads the raised generation from the stored `timekeeping_ownership` row and stops that generation minus one, so a restarted runner gets the same answer."
      build.call.stop_applying!
      ownership = TimekeepingOwnership.current.reload
      expect(ownership.settling_stopped_generation).to eq(4)
      expect(ownership.settling_generation).to be_nil
    end
  end

  context "more tests 17" do
    it "the Timekeeping port is not settled while Timekeeping reports a prepared operation, and stops the raised generation minus one" do
      TimekeepingOwnership.current.update_columns(generation: 5, handoff_step: "settle")
      store = instance_double(Timekeeping::Handoff::TimekeepingStore)
      allow(store).to receive(:settle).and_return(
        Timekeeping::Handoff::TimekeepingStore::SettleAnswer.new(settling: true, prepared_operations: 1)
      )
      allow(store).to receive(:stop_applying).and_return(nil)
      connection = ActiveRecord::Base.connection
      settle = described_class.new(owner: described_class::TimekeepingPort.new(store:),
                                   reservations: Object.new, connection:)

      expect(InvoiceOperationIntent.where(state: "pending")).not_to exist
      # "`settled?` is true only when no `invoice_operation_intents` row is 'pending' and the owner reports no 'prepared' operation."
      expect(settle.settled?).to be(false)

      settle.stop_applying!
      expect(store).to have_received(:stop_applying).with(generation: 4)
      expect(store).not_to have_received(:stop_applying).with(generation: 5)
    end
  end

  context "more tests 18", "repeated settle" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "a repeated settle! applies a committed intent's commit once across both runs" do
      g = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
      InvoiceOperationIntent.create!(company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id,
                                     generation: g, disposition: "active", desired_entry_ids: [entry.id],
                                     state: "committed", created_at: 1.minute.ago)
      row_id = InvoiceOperationOutboxItem.record!(kind: "commit", company_id: company.id, invoice_id: invoice.id,
                                                  operation_id: request.operation_id, generation: g,
                                                  disposition: "active", desired_entry_ids: [entry.id])
      TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: "settle")

      calls = []
      inner = Invoices::PreparedReservations.new
      reservations = Object.new
      reservations.define_singleton_method(:commit) { |req| calls << [:commit, req.operation_id]; inner.commit(req) }
      reservations.define_singleton_method(:abort) { |req| calls << [:abort, req.operation_id]; inner.abort(req) }
      connection = ActiveRecord::Base.connection
      settle = described_class.new(
        owner: described_class::MonolithPort.new(connection:), reservations:, connection:
      )

      settle.settle!(generation: g + 1)
      after_first = [prepared_spec_operations(company, invoice), prepared_spec_reservations(company),
                     InvoiceOperationOutboxItem.find(row_id).delivered_at]
      settle.settle!(generation: g + 1)

      # "A repeated `settle!` applies no commit twice."
      expect(calls).to eq([[:commit, request.operation_id]])
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
      expect([prepared_spec_operations(company, invoice), prepared_spec_reservations(company),
              InvoiceOperationOutboxItem.find(row_id).delivered_at]).to eq(after_first)
      expect(settle.settled?).to be(true)
    end
  end

  context "more tests 19", "stale generation redelivery" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "settle! redelivers and resolves a commit row a stale_generation answer marked undeliverable" do
      g = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      expect(Invoices::PreparedReservations.new.prepare(request).state).to eq("prepared")
      InvoiceOperationIntent.create!(company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id,
                                     generation: g, disposition: "active", desired_entry_ids: [entry.id],
                                     state: "committed", created_at: 1.minute.ago)
      row_id = InvoiceOperationOutboxItem.record!(kind: "commit", company_id: company.id, invoice_id: invoice.id,
                                                  operation_id: request.operation_id, generation: g,
                                                  disposition: "active", desired_entry_ids: [entry.id])
      InvoiceOperationOutboxItem.where(id: row_id).update_all(undeliverable_at: Time.current)
      TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: "settle")

      commits = []
      inner = Invoices::PreparedReservations.new
      reservations = Object.new
      reservations.define_singleton_method(:commit) { |req| commits << req.operation_id; inner.commit(req) }
      reservations.define_singleton_method(:abort) { |req| inner.abort(req) }
      connection = ActiveRecord::Base.connection
      settle = described_class.new(
        owner: described_class::MonolithPort.new(connection:), reservations:, connection:
      )

      settle.settle!(generation: g + 1)

      # "A row marked undeliverable by stale_generation is redelivered and resolved."
      # A settle! that delivers without clearing the mark leaves this row skipped and the operation prepared.
      row = InvoiceOperationOutboxItem.find(row_id)
      expect(row.delivered_at).to be_present
      expect(row.undeliverable_at).to be_nil
      expect(commits).to eq([request.operation_id])
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["committed"])
    end
  end

  context "more tests 20", "restart between settle and stop" do
    include TimekeepingLocalOwnerSpecHelpers

    it "stop_applying! on a fresh instance after settle!(generation: 5) stops 4 and never the raised generation" do
      prepare_local_ownership!
      TimekeepingOwnership.current.update_columns(generation: 5, handoff_step: "settle")
      connection = ActiveRecord::Base.connection
      build = lambda do
        described_class.new(owner: described_class::MonolithPort.new(connection:),
                            reservations: Invoices::PreparedReservations.new, connection:)
      end

      build.call.settle!(generation: 5)
      # "`settle!(generation: 5)` begins settling at 4."
      expect(TimekeepingOwnership.current.settling_generation).to eq(4)

      # A restarted runner holds no generation in memory.
      build.call.stop_applying!

      # "It reads the raised generation from the stored `timekeeping_ownership` row and stops that generation minus one, so a restarted runner gets the same answer."
      ownership = TimekeepingOwnership.current
      expect(ownership.settling_stopped_generation).to eq(4)
      expect(ownership.settling_generation).to be_nil
      expect(ownership.generation).to eq(5)
    end
  end

  context "more tests 21", "settling not open" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

    it "settle! with no open handoff raises NotSettling and leaves an undeliverable row marked" do
      g = prepare_local_ownership!.generation
      company = create(:company)
      entry = prepared_spec_entry(company)
      invoice = prepared_spec_invoice(company)
      request = prepared_spec_request(company, invoice, [entry.id])
      Invoices::PreparedReservations.new.prepare(request)
      InvoiceOperationIntent.create!(company_id: company.id, invoice_id: invoice.id, operation_id: request.operation_id,
                                     generation: g, disposition: "active", desired_entry_ids: [entry.id],
                                     state: "committed", created_at: 1.minute.ago)
      row_id = InvoiceOperationOutboxItem.record!(kind: "commit", company_id: company.id, invoice_id: invoice.id,
                                                  operation_id: request.operation_id, generation: g,
                                                  disposition: "active", desired_entry_ids: [entry.id])
      InvoiceOperationOutboxItem.where(id: row_id).update_all(undeliverable_at: Time.current)
      # The generation is raised but no handoff step is recorded, so begin_settling! opens nothing.
      TimekeepingOwnership.current.update_columns(generation: g + 1, handoff_step: nil)
      connection = ActiveRecord::Base.connection
      settle = described_class.new(owner: described_class::MonolithPort.new(connection:),
                                   reservations: Invoices::PreparedReservations.new, connection:)

      # Clearing the mark before settling opens would only have the owner refuse the row as stale again.
      expect { settle.settle!(generation: g + 1) }.to raise_error(described_class::NotSettling)
      row = InvoiceOperationOutboxItem.find(row_id)
      expect(row.undeliverable_at).to be_present
      expect(row.delivered_at).to be_nil
      expect(prepared_spec_operations(company, invoice).map(&:first)).to eq(["prepared"])
    end
  end

  context "older generation marks" do
    include PreparedReservationsSpecSupport
    include TimekeepingLocalOwnerSpecHelpers

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
      connection = ActiveRecord::Base.connection
      settle = described_class.new(owner: described_class::MonolithPort.new(connection:),
                                   reservations: Invoices::PreparedReservations.new, connection:)

      settle.settle!(generation: g + 2)

      row = InvoiceOperationOutboxItem.find(row_id)
      expect(row.undeliverable_at).to be_present
      expect(row.delivered_at).to be_nil
    end
  end
end

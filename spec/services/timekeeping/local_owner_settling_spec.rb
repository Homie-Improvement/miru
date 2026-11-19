# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Timekeeping::LocalOwner do
  context "more tests 10", "settling across companies" do
    it "refuses a settling commit that names another company's registered operation id as stale and leaves that company's operation prepared" do
      outgoing = prepare_local_ownership!.generation
      owning = seeded_invoice_entry
      other = seeded_invoice_entry
      operation_id = SecureRandom.uuid
      grant = %w[reservations.prepare reservations.commit]
      owning_actor = described_class::Actor.service(name: "invoices", company_id: owning.company.id, operations: grant)
      other_actor = described_class::Actor.service(name: "invoices", company_id: other.company.id, operations: grant)

      prepared = reservation_call(:prepare, company: owning.company, generation: outgoing.to_s, actor: owning_actor,
                                            invoice: owning.invoice, operation_id:, entry_ids: [owning.entry.id])
      expect(prepared.body["state"]).to eq("prepared")

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      baseline = timekeeping_row_counts
      entry_before = owning.entry.reload.attributes

      # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort; it
      # carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations, found by
      # company, actor and operation id, stored at that generation."
      # "Everything else is refused as stale, with no stored change."
      outcome = reservation_call(:commit, company: other.company, generation: outgoing.to_s, actor: other_actor,
                                          invoice: other.invoice, operation_id:)

      expect(outcome.status).to eq(409)
      expect(outcome.body).to eq("reason" => "stale_generation")
      expect(timekeeping_row_counts).to eq(baseline)
      expect(owning.entry.reload.attributes).to eq(entry_before)
      state = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", owning.company.id, operation_id]
      ))
      expect(state).to eq("prepared")
    end
  end

  context "more tests 11", "settling generation input" do
    it "refuses a settling commit whose generation is missing, blank or not a number as stale and still applies the exact settling generation" do
      outgoing = prepare_local_ownership!.generation
      seed = seeded_invoice_entry
      operation_id = SecureRandom.uuid
      actor = described_class::Actor.service(name: "invoices", company_id: seed.company.id,
                                             operations: %w[reservations.prepare reservations.commit])
      reservation_call(:prepare, company: seed.company, generation: outgoing.to_s, actor:, invoice: seed.invoice,
                                 operation_id:, entry_ids: [seed.entry.id])

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      baseline = timekeeping_row_counts
      operation_state = lambda do
        ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
          ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", seed.company.id, operation_id]
        ))
      end

      # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort; it
      # carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations, found by
      # company, actor and operation id, stored at that generation."
      [nil, "", "abc", "#{outgoing}x", (outgoing + 1).to_s].each do |sent|
        outcome = reservation_call(:commit, company: seed.company, generation: sent, actor:, invoice: seed.invoice,
                                            operation_id:)

        expect(outcome.body).to eq("reason" => "stale_generation"), "generation #{sent.inspect} was not refused"
        expect(timekeeping_row_counts).to eq(baseline)
        expect(operation_state.call).to eq("prepared")
      end

      applied = reservation_call(:commit, company: seed.company, generation: outgoing.to_s, actor:, invoice: seed.invoice,
                                          operation_id:)
      expect(applied.status).to eq(200)
      expect(operation_state.call).to eq("committed")
    end
  end

  context "more tests 12", "settling reservations" do
    it "service route applies a settling commit and then refuses the identical commit as stale after stop_applying! without replaying its receipt" do
      outgoing = prepare_local_ownership!.generation
      generation = outgoing.to_s
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: ["reservations.prepare", "reservations.commit"])
      operation_id = SecureRandom.uuid
      prepared = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
      expect(prepared.status).to be_between(200, 299)

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      operation_state = lambda do
        ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
          ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
        ))
      end
      expect(operation_state.call).to eq("prepared")

      # "a commit of a prepared operation at the outgoing generation is applied."
      committed = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
      expect(committed.status).to be_between(200, 299)
      expect(operation_state.call).to eq("committed")

      TimekeepingOwnership.stop_applying!(generation: outgoing)
      baseline = timekeeping_row_counts
      version = entry.reload.version

      # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
      2.times do
        refused = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
        expect(refused.status).to eq(409)
        expect(refused.body).to eq("reason" => "stale_generation")
        expect(timekeeping_row_counts).to eq(baseline)
        expect(entry.reload.version).to eq(version)
        expect(operation_state.call).to eq("committed")
      end
    end
  end

  context "more tests 13", "settling across companies" do
    it "while settling, a commit naming another company's registered operation id is refused as stale and leaves that company's operation prepared" do
      outgoing = prepare_local_ownership!.generation
      seeded_invoice_entry => { company: company_a, invoice: invoice_a }
      seeded_invoice_entry => { company: company_b, invoice: invoice_b, entry: entry_b }
      operations = %w[reservations.prepare reservations.commit]
      actor_a = described_class::Actor.service(name: "invoices", company_id: company_a.id, operations:)
      actor_b = described_class::Actor.service(name: "invoices", company_id: company_b.id, operations:)
      operation_id = SecureRandom.uuid
      prepared = reservation_call(:prepare, company: company_b, generation: outgoing.to_s, actor: actor_b,
                                            invoice: invoice_b, operation_id:, entry_ids: [entry_b.id])
      expect(prepared.status).to eq(200)

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      operation_state_b = lambda do
        ActiveRecord::Base.connection.select_values(ActiveRecord::Base.sanitize_sql_array(
          ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company_b.id, operation_id]
        ))
      end
      counts_before = timekeeping_row_counts
      entry_b_before = entry_b.reload.attributes

      # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort;
      # it carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations,
      # found by company, actor and operation id, stored at that generation."
      # "Everything else is refused as stale, with no stored change."
      foreign = reservation_call(:commit, company: company_a, generation: outgoing.to_s, actor: actor_a,
                                          invoice: invoice_a, operation_id:)

      expect(foreign.body).to eq("reason" => "stale_generation")
      expect(timekeeping_row_counts).to eq(counts_before)
      expect(entry_b.reload.attributes).to eq(entry_b_before)
      expect(operation_state_b.call).to eq(["prepared"])

      # The owning company's own commit at the outgoing generation is applied, so the refusal above
      # comes from the company boundary and not from a settle step that admits nothing.
      owned = reservation_call(:commit, company: company_b, generation: outgoing.to_s, actor: actor_b,
                                        invoice: invoice_b, operation_id:)
      expect(owned.status).to eq(200)
      expect(operation_state_b.call).to eq(["committed"])
    end
  end

  context "more tests 14", "settling commit applied" do
    it "service route applies a commit of a prepared operation at the outgoing generation while settling" do
      outgoing = prepare_local_ownership!.generation
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit reservations.abort])
      operation_id = SecureRandom.uuid
      prepared = reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:,
                                            entry_ids: [entry.id])
      expect(prepared.status).to eq(200)

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      state = lambda do
        ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
          ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
        ))
      end
      expect(state.call).to eq("prepared")

      # "a commit of a prepared operation at the outgoing generation is applied."
      outcome = reservation_call(:commit, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:)

      expect(outcome.status).to eq(200)
      expect(outcome.body).not_to eq("reason" => "stale_generation")
      expect(state.call).to eq("committed")
    end
  end

  context "more tests 15", "settling abort applied" do
    it "service route applies an abort of a prepared operation at the outgoing generation while settling" do
      outgoing = prepare_local_ownership!.generation
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit reservations.abort])
      operation_id = SecureRandom.uuid
      reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:, entry_ids: [entry.id])

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)

      # "While settling, the monolith applies a commit or abort of an operation it registered at the outgoing generation, through both LocalOwner::ReservationOperations and Invoices::PreparedReservations, and refuses prepares"
      outcome = reservation_call(:abort, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:)

      expect(outcome.status).to eq(200)
      state = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
      ))
      expect(state).to eq("aborted")
      provisional = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT COUNT(*) FROM reservations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
      )).to_i
      expect(provisional).to eq(0)
    end
  end

  context "more tests 16", "settling commit after stop" do
    it "service route refuses the same commit as stale after stop_applying! without replaying its receipt" do
      outgoing = prepare_local_ownership!.generation
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit reservations.abort])
      operation_id = SecureRandom.uuid
      reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:, entry_ids: [entry.id])
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      commit = -> { reservation_call(:commit, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:) }
      expect(commit.call.status).to eq(200)

      TimekeepingOwnership.stop_applying!(generation: outgoing)
      baseline = timekeeping_row_counts
      entry_before = entry.reload.attributes

      # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
      outcome = commit.call

      expect(outcome.body).to eq("reason" => "stale_generation")
      expect(outcome.status).to eq(409)
      # "Everything else is refused as stale, with no stored change."
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.attributes).to eq(entry_before)
    end
  end

  context "more tests 17", "settling refusals" do
    it "service route refuses a prepare, an unknown operation and an older-generation operation while settling" do
      older = prepare_local_ownership!.generation
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit reservations.abort])
      old_operation_id = SecureRandom.uuid
      reservation_call(:prepare, company:, generation: older.to_s, actor:, invoice:, operation_id: old_operation_id,
                                 entry_ids: [entry.id])
      outgoing = older + 1
      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      baseline = timekeeping_row_counts
      entry_before = entry.reload.attributes

      # "A new prepare ... and a commit for an unknown operation are refused." A commit for an operation stored at an older generation is refused too.
      answers = [
        reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id: SecureRandom.uuid,
                                   entry_ids: [entry.id]),
        reservation_call(:commit, company:, generation: outgoing.to_s, actor:, invoice:, operation_id: SecureRandom.uuid),
        reservation_call(:commit, company:, generation: outgoing.to_s, actor:, invoice:, operation_id: old_operation_id)
      ]

      answers.each { |answer| expect(answer.body).to eq("reason" => "stale_generation") }
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.attributes).to eq(entry_before)
      state = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, old_operation_id]
      ))
      expect(state).to eq("prepared")
    end
  end

  context "more tests 18", "settle step re-sent commit" do
    it "answers the identical commit re-sent after stop_applying! as stale_generation instead of replaying its receipt" do
      outgoing = prepare_local_ownership!.generation
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit])
      operation_id = SecureRandom.uuid
      prepared = reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:,
                                            entry_ids: [entry.id])
      expect(prepared.status).to eq(200)

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      applied = reservation_call(:commit, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:)
      expect(applied.status).to eq(200)

      TimekeepingOwnership.stop_applying!(generation: outgoing)
      counts_before = timekeeping_row_counts
      entry_before = entry.reload.attributes

      # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
      resent = reservation_call(:commit, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:)

      expect(resent.body).to eq("reason" => "stale_generation")
      expect(resent.status).not_to eq(200)
      expect(resent.body).not_to eq(applied.body)
      # "Everything else is refused as stale, with no stored change."
      expect(timekeeping_row_counts).to eq(counts_before)
      expect(entry.reload.attributes).to eq(entry_before)
    end
  end

  context "more tests 19", "settle step raised generation" do
    it "refuses a settling commit that carries the raised generation instead of the settling generation" do
      outgoing = prepare_local_ownership!.generation
      seeded_invoice_entry => { company:, invoice:, entry: }
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit])
      operation_id = SecureRandom.uuid
      reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:, entry_ids: [entry.id])

      TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
      TimekeepingOwnership.begin_settling!(generation: outgoing)
      counts_before = timekeeping_row_counts
      entry_before = entry.reload.attributes

      # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort;
      # it carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations,
      # found by company, actor and operation id, stored at that generation."
      outcome = reservation_call(:commit, company:, generation: (outgoing + 1).to_s, actor:, invoice:, operation_id:)

      expect(outcome.body).to eq("reason" => "stale_generation")
      expect(timekeeping_row_counts).to eq(counts_before)
      expect(entry.reload.attributes).to eq(entry_before)
      state = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
      ))
      expect(state).to eq("prepared")
    end
  end
end

RSpec.describe Timekeeping::LocalOwner, "settle step closed states" do
  def settle_closed_commit_setup
    outgoing = prepare_local_ownership!.generation
    seed = seeded_invoice_entry
    actor = described_class::Actor.service(name: "invoices", company_id: seed.company.id,
                                           operations: %w[reservations.prepare reservations.commit])
    operation_id = SecureRandom.uuid
    reservation_call(:prepare, company: seed.company, generation: outgoing.to_s, actor:, invoice: seed.invoice,
                               operation_id:, entry_ids: [seed.entry.id])
    commit = lambda do
      reservation_call(:commit, company: seed.company, generation: outgoing.to_s, actor:, invoice: seed.invoice,
                                operation_id:)
    end
    { outgoing:, seed:, commit: }
  end

  it "refuses a commit at the outgoing generation as stale while a handoff step is recorded but no settle step was begun" do
    settle_closed_commit_setup => { outgoing:, seed:, commit: }
    TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "close_admission")
    baseline = timekeeping_row_counts
    entry_before = seed.entry.reload.attributes

    outcome = commit.call

    expect(outcome.status).to eq(409)
    expect(outcome.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(baseline)
    expect(seed.entry.reload.attributes).to eq(entry_before)
  end

  it "refuses a commit as stale while only the admission fence mark is set, before any handoff step" do
    settle_closed_commit_setup => { seed:, commit: }
    TimekeepingOwnership.current.update_columns(admission_fenced_at: Time.current)
    baseline = timekeeping_row_counts
    entry_before = seed.entry.reload.attributes

    outcome = commit.call

    expect(outcome.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(baseline)
    expect(seed.entry.reload.attributes).to eq(entry_before)
  end

  # "While settling, the monolith also refuses new entry writes and service commands (through LocalOwner,
  # BillingFence and Gateway), with nothing changed"
  it "refuses a mark_billed service command and a billing fence write while the settle step is open, changing nothing" do
    settle_closed_commit_setup => { outgoing:, seed: }
    TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
    TimekeepingOwnership.begin_settling!(generation: outgoing)
    baseline = timekeeping_row_counts
    entry_before = seed.entry.reload.attributes
    billing = described_class::Actor.service(name: "invoice-boundary", company_id: seed.company.id,
                                             operations: ["invoices.mark_billed"])

    [outgoing, outgoing + 1].each do |generation|
      outcome = described_class.call(operation: :mark_billed, company_id: seed.company.id, generation: generation.to_s,
                                     actor: billing, params: { "invoice_id" => seed.invoice.id,
                                                               "operation_id" => SecureRandom.uuid })
      expect(outcome.body).to eq("reason" => "stale_generation")
    end
    ran = false
    expect { Timekeeping::BillingFence.transaction { ran = true } }.to raise_error(Timekeeping::BillingFence::OwnershipMoving)

    expect(ran).to be(false)
    expect(timekeeping_row_counts).to eq(baseline)
    expect(seed.entry.reload.attributes).to eq(entry_before)
  end
end

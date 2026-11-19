# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Timekeeping::LocalOwner, "settle step reservations" do
  def settling_spec_operation_state(company, operation_id)
    ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
    ))
  end

  def settling_spec_actor(company)
    described_class::Actor.service(name: "invoices", company_id: company.id,
                                   operations: %w[reservations.prepare reservations.commit reservations.abort])
  end

  def settling_spec_open(outgoing)
    TimekeepingOwnership.current.update_columns(generation: outgoing + 1, handoff_step: "settle")
    TimekeepingOwnership.begin_settling!(generation: outgoing)
  end

  it "service route applies a settling commit and then refuses the identical commit as stale after stop_applying! without replaying its receipt" do
    outgoing = prepare_local_ownership!.generation
    generation = outgoing.to_s
    seeded_invoice_entry => { company:, invoice:, entry: }
    actor = settling_spec_actor(company)
    operation_id = SecureRandom.uuid
    prepared = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    expect(prepared.status).to eq(200)

    settling_spec_open(outgoing)
    expect(settling_spec_operation_state(company, operation_id)).to eq("prepared")

    # "a commit of a prepared operation at the outgoing generation is applied."
    committed = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
    expect(committed.status).to eq(200)
    expect(settling_spec_operation_state(company, operation_id)).to eq("committed")

    TimekeepingOwnership.stop_applying!(generation: outgoing)
    baseline = timekeeping_row_counts
    entry_before = entry.reload.attributes

    # "After `stop_applying!` the same commit is refused as stale", using the exact same request.
    # "Everything else is refused as stale, with no stored change."
    2.times do
      refused = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
      expect(refused.status).to eq(409)
      expect(refused.body).to eq("reason" => "stale_generation")
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.attributes).to eq(entry_before)
      expect(settling_spec_operation_state(company, operation_id)).to eq("committed")
    end
  end

  it "service route applies an abort of a prepared operation at the outgoing generation while settling" do
    outgoing = prepare_local_ownership!.generation
    seeded_invoice_entry => { company:, invoice:, entry: }
    actor = settling_spec_actor(company)
    operation_id = SecureRandom.uuid
    reservation_call(:prepare, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    settling_spec_open(outgoing)

    # "While settling, the monolith applies a commit or abort of an operation it registered at the outgoing generation, through both LocalOwner::ReservationOperations and Invoices::PreparedReservations, and refuses prepares"
    outcome = reservation_call(:abort, company:, generation: outgoing.to_s, actor:, invoice:, operation_id:)

    expect(outcome.status).to eq(200)
    expect(settling_spec_operation_state(company, operation_id)).to eq("aborted")
    provisional = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT COUNT(*) FROM reservations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
    )).to_i
    expect(provisional).to eq(0)
  end

  it "while settling, a commit naming another company's registered operation id is refused as stale and leaves that company's operation prepared" do
    outgoing = prepare_local_ownership!.generation
    seeded_invoice_entry => { company: company_a, invoice: invoice_a }
    seeded_invoice_entry => { company: company_b, invoice: invoice_b, entry: entry_b }
    actor_a = settling_spec_actor(company_a)
    actor_b = settling_spec_actor(company_b)
    operation_id = SecureRandom.uuid
    prepared = reservation_call(:prepare, company: company_b, generation: outgoing.to_s, actor: actor_b,
                                          invoice: invoice_b, operation_id:, entry_ids: [entry_b.id])
    expect(prepared.status).to eq(200)

    settling_spec_open(outgoing)
    counts_before = timekeeping_row_counts
    entry_b_before = entry_b.reload.attributes

    # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort;
    # it carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations,
    # found by company, actor and operation id, stored at that generation."
    # "Everything else is refused as stale, with no stored change."
    foreign = reservation_call(:commit, company: company_a, generation: outgoing.to_s, actor: actor_a,
                                        invoice: invoice_a, operation_id:)

    expect(foreign.status).to eq(409)
    expect(foreign.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(counts_before)
    expect(entry_b.reload.attributes).to eq(entry_b_before)
    expect(settling_spec_operation_state(company_b, operation_id)).to eq("prepared")

    # The owning company's own commit at the outgoing generation is applied, so the refusal above
    # comes from the company boundary and not from a settle step that admits nothing.
    owned = reservation_call(:commit, company: company_b, generation: outgoing.to_s, actor: actor_b,
                                      invoice: invoice_b, operation_id:)
    expect(owned.status).to eq(200)
    expect(settling_spec_operation_state(company_b, operation_id)).to eq("committed")
  end

  it "refuses a settling commit whose generation is missing, blank, not a number or the raised one as stale and still applies the exact settling generation" do
    outgoing = prepare_local_ownership!.generation
    seed = seeded_invoice_entry
    operation_id = SecureRandom.uuid
    actor = settling_spec_actor(seed.company)
    reservation_call(:prepare, company: seed.company, generation: outgoing.to_s, actor:, invoice: seed.invoice,
                               operation_id:, entry_ids: [seed.entry.id])

    settling_spec_open(outgoing)
    baseline = timekeeping_row_counts
    entry_before = seed.entry.reload.attributes

    # "While `handoff_step` is set, a path applies a request only when all three hold: it is a commit or abort; it
    # carries exactly `settling_generation`; and the operation exists in the monolith's invoice_operations, found by
    # company, actor and operation id, stored at that generation."
    [nil, "", "abc", "#{outgoing}x", (outgoing + 1).to_s].each do |sent|
      outcome = reservation_call(:commit, company: seed.company, generation: sent, actor:, invoice: seed.invoice,
                                          operation_id:)

      expect(outcome.body).to eq("reason" => "stale_generation"), "generation #{sent.inspect} was not refused"
      expect(timekeeping_row_counts).to eq(baseline)
      expect(seed.entry.reload.attributes).to eq(entry_before)
      expect(settling_spec_operation_state(seed.company, operation_id)).to eq("prepared")
    end

    applied = reservation_call(:commit, company: seed.company, generation: outgoing.to_s, actor:, invoice: seed.invoice,
                                        operation_id:)
    expect(applied.status).to eq(200)
    expect(settling_spec_operation_state(seed.company, operation_id)).to eq("committed")
  end

  it "service route refuses a prepare, an unknown operation and an older-generation operation while settling" do
    older = prepare_local_ownership!.generation
    seeded_invoice_entry => { company:, invoice:, entry: }
    actor = settling_spec_actor(company)
    old_operation_id = SecureRandom.uuid
    reservation_call(:prepare, company:, generation: older.to_s, actor:, invoice:, operation_id: old_operation_id,
                               entry_ids: [entry.id])
    outgoing = older + 1
    settling_spec_open(outgoing)
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
    expect(settling_spec_operation_state(company, old_operation_id)).to eq("prepared")
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

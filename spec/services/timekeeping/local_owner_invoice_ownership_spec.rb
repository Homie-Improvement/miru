# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "foreign invoice id on prepare" do
  it "prepare carrying another company's invoice id answers 404 not_found before any lock and writes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    seeded_invoice_entry => { company:, entry: }
    foreign_invoice = seeded_invoice_entry.invoice
    actor = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.prepare"])
    entry_before = entry.reload.attributes
    baseline = timekeeping_row_counts
    steps = []

    # "A shared contract example that sends a prepare and a mark-billed carrying another company's invoice id gets 404 not_found and no writes on all three providers, LocalOwner included."
    outcome = reservation_call(:prepare, company:, generation:, actor:, invoice: foreign_invoice,
                                         operation_id: SecureRandom.uuid, entry_ids: [entry.id],
                                         checkpoint: ->(step) { steps << step })

    expect([outcome.status, outcome.body]).to eq([404, { "reason" => "not_found" }])
    expect(steps).not_to include(:operation_key_locked)
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.attributes).to eq(entry_before)
    expect(Timekeeping::LocalEntry.with_reserved.find(entry.id).reserved).to be(false)
  end
end

RSpec.describe Timekeeping::LocalOwner, "foreign invoice id on a replayed prepare" do
  it "prepare reusing a stored operation_id with another company's invoice id answers 404 not_found instead of a replay" do
    generation = prepare_local_ownership!.generation.to_s
    seeded_invoice_entry => { company:, invoice:, entry: }
    foreign_invoice = seeded_invoice_entry.invoice
    actor = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.prepare"])
    operation_id = SecureRandom.uuid
    own = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    expect(own.status).to eq(200)
    baseline = timekeeping_row_counts
    entry_before = entry.reload.attributes

    # The owner check runs before the stored answer is read, so the stored
    # operation under this key never answers a request naming a foreign invoice.
    foreign = reservation_call(:prepare, company:, generation:, actor:, invoice: foreign_invoice, operation_id:,
                                         entry_ids: [entry.id])

    expect([foreign.status, foreign.body]).to eq([404, { "reason" => "not_found" }])
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.attributes).to eq(entry_before)
  end
end

RSpec.describe Timekeeping::LocalOwner, "foreign invoice id on mark_billed" do
  it "mark_billed carrying another company's invoice id answers 404 not_found, bills nothing and stores no receipt, also on retry" do
    generation = prepare_local_ownership!.generation.to_s
    seeded_invoice_entry => { company:, entry: }
    foreign_invoice = seeded_invoice_entry.invoice
    # The requester's own entry holds a committed reservation under the foreign
    # invoice id, so a provider that skipped the owner check would bill it.
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, foreign_invoice.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    actor = described_class::Actor.service(name: "invoice-boundary", company_id: company.id,
                                           operations: ["invoices.mark_billed"])
    params = { "invoice_id" => foreign_invoice.id, "operation_id" => SecureRandom.uuid }
    baseline = timekeeping_row_counts

    # "A shared contract example that sends a prepare and a mark-billed carrying another company's invoice id gets 404 not_found and no writes on all three providers, LocalOwner included."
    first = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:, params:)
    retried = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:, params:)

    expect([first.status, first.body]).to eq([404, { "reason" => "not_found" }])
    expect([retried.status, retried.body]).to eq([404, { "reason" => "not_found" }])
    expect(entry.reload.bill_status).to eq("unbilled")
    expect(timekeeping_row_counts).to eq(baseline)
  end
end

RSpec.describe Timekeeping::LocalOwner, "stale operation rows for a foreign invoice" do
  it "an invoice_operations row the requester already holds for another company's invoice does not admit prepare or mark_billed" do
    generation = prepare_local_ownership!.generation.to_s
    seeded_invoice_entry => { company:, entry: }
    foreign_invoice = seeded_invoice_entry.invoice
    # Rows a prepare could store before invoice ownership was checked: an
    # operation and a committed reservation of the requester under the
    # foreign invoice id.
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, foreign_invoice.id, SecureRandom.uuid]))
      INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, disposition, generation, created_at)
      VALUES (?, ?, ?, 'invoices', 'committed', 'active', 1, NOW())
    SQL
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, foreign_invoice.id, SecureRandom.uuid]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
    SQL
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: %w[reservations.prepare invoices.mark_billed])
    other_entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: entry.user_id, project_id: entry.project_id,
                                                  work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    baseline = timekeeping_row_counts

    prepared = reservation_call(:prepare, company:, generation:, actor:, invoice: foreign_invoice,
                                          operation_id: SecureRandom.uuid, entry_ids: [other_entry.id])
    billed = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:,
                                  params: { "invoice_id" => foreign_invoice.id, "operation_id" => SecureRandom.uuid })

    expect([prepared.status, prepared.body]).to eq([404, { "reason" => "not_found" }])
    expect([billed.status, billed.body]).to eq([404, { "reason" => "not_found" }])
    expect(entry.reload.bill_status).to eq("unbilled")
    expect(timekeeping_row_counts).to eq(baseline)
  end
end

RSpec.describe Timekeeping::LocalOwner, "foreign and unknown invoice ids" do
  it "the refusal for another company's invoice id is the same as for an invoice id that does not exist" do
    generation = prepare_local_ownership!.generation.to_s
    seeded_invoice_entry => { company:, entry: }
    foreign_invoice_id = seeded_invoice_entry.invoice.id
    unknown_invoice_id = foreign_invoice_id + 1_000_000
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: %w[reservations.prepare invoices.mark_billed])
    answers = [foreign_invoice_id, unknown_invoice_id].map do |invoice_id|
      prepared = described_class.call(
        operation: :prepare, company_id: company.id, generation:, actor:,
        params: { "invoice_id" => invoice_id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                  "entry_ids" => [entry.id] }
      )
      billed = described_class.call(operation: :mark_billed, company_id: company.id, generation:, actor:,
                                    params: { "invoice_id" => invoice_id, "operation_id" => SecureRandom.uuid })
      [[prepared.status, prepared.body], [billed.status, billed.body]]
    end

    # An answer that differed would tell the caller that another company holds the id.
    expect(answers.first).to eq([[404, { "reason" => "not_found" }], [404, { "reason" => "not_found" }]])
    expect(answers.last).to eq(answers.first)
  end
end

RSpec.describe Timekeeping::LocalOwner::InvoiceOwnership do
  it "owned? answers false for another company's invoice, for the requester's operation row naming it, and for another company's operation row" do
    company = create(:company)
    other_company = create(:company)
    foreign_invoice_id = create(:invoice, company: other_company, client: create(:client, company: other_company)).id
    rowless_id = 900_000_011
    store_operation = lambda do |company_id, invoice_id|
      Timekeeping::LocalOwner::ReservationOperations::InvoiceOperation.create!(
        company_id:, invoice_id:, operation_id: SecureRandom.uuid, actor_name: "invoices", state: "committed",
        desired_entry_ids: [], disposition: "active", generation: 1, created_at: Time.current
      )
    end

    expect(described_class.owned?(company_id: company.id, invoice_id: foreign_invoice_id)).to be(false)

    store_operation.call(company.id, foreign_invoice_id)
    expect(described_class.owned?(company_id: company.id, invoice_id: foreign_invoice_id)).to be(false)

    store_operation.call(other_company.id, rowless_id)
    expect(described_class.owned?(company_id: company.id, invoice_id: rowless_id)).to be(false)
    # The other company's own row still counts for it, so the false above comes from the company scope.
    expect(described_class.owned?(company_id: other_company.id, invoice_id: rowless_id)).to be(true)
  end
end

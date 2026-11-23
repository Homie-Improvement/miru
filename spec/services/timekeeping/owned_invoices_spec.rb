require "rails_helper"

RSpec.describe Timekeeping::OwnedInvoices do
  context "more tests 2" do
  it "lists the company's invoices and its intents in any state, and leaves out another company's invoice and intent like an unknown id" do
    company = create(:company)
    other_company = create(:company)
    own_invoice = create(:invoice, company:, client: create(:client, company:))
    foreign_invoice = create(:invoice, company: other_company, client: create(:client, company: other_company))
    base = Invoice.maximum(:id).to_i
    pending_id, failed_id, foreign_intent_id, unknown_id = (1..4).map { |offset| base + 9000 + offset }
    InvoiceOperationIntent.create!(company_id: company.id, invoice_id: pending_id, operation_id: SecureRandom.uuid,
                                   state: "pending", generation: 1)
    InvoiceOperationIntent.create!(company_id: company.id, invoice_id: failed_id, operation_id: SecureRandom.uuid,
                                   state: "failed", generation: 1)
    InvoiceOperationIntent.create!(company_id: other_company.id, invoice_id: foreign_intent_id,
                                   operation_id: SecureRandom.uuid, state: "pending", generation: 1)

    ids = described_class.ids(
      company_id: company.id,
      invoice_ids: [own_invoice.id, foreign_invoice.id, pending_id, failed_id, foreign_intent_id, unknown_id]
    )

    expect(ids).to contain_exactly(own_invoice.id, pending_id, failed_id)
    expect(described_class.ids(company_id: company.id, invoice_ids: [])).to eq([])
  end
  end

  context "more tests 3" do
  it "lists only the path company's invoices and intents, leaving another company's out exactly like an unknown id" do
    company = create(:company)
    other_company = create(:company)
    own_invoice = create(:invoice, company:, client: create(:client, company:))
    foreign_invoice = create(:invoice, company: other_company, client: create(:client, company: other_company))
    own_intent_id = 900_000_001
    foreign_intent_id = 900_000_002
    unknown_id = 900_000_003
    InvoiceOperationIntent.create!(company_id: company.id, invoice_id: own_intent_id, operation_id: SecureRandom.uuid,
                                   state: "failed", generation: 1)
    InvoiceOperationIntent.create!(company_id: other_company.id, invoice_id: foreign_intent_id,
                                   operation_id: SecureRandom.uuid, state: "pending", generation: 1)
    requested = [own_invoice.id, foreign_invoice.id, own_intent_id, foreign_intent_id, unknown_id]

    expect(described_class.ids(company_id: company.id, invoice_ids: requested)).to contain_exactly(own_invoice.id, own_intent_id)
    expect(described_class.ids(company_id: other_company.id, invoice_ids: requested))
      .to contain_exactly(foreign_invoice.id, foreign_intent_id)
  end
  end

  context "more tests 4" do
  it "lists the company's kept and discarded invoices and its pending and failed intents, and leaves out another company's invoice and intent" do
    company = create(:company)
    other_company = create(:company)
    client = create(:client, company:)
    kept = create(:invoice, company:, client:).id
    discarded = create(:invoice, company:, client:).tap { |invoice| invoice.update_columns(discarded_at: Time.current) }.id
    foreign = create(:invoice, company: other_company, client: create(:client, company: other_company)).id
    base = Invoice.maximum(:id).to_i + 1_000
    pending_intent, failed_intent, foreign_intent, unknown = (1..4).map { |offset| base + offset }
    InvoiceOperationIntent.create!(company_id: company.id, invoice_id: pending_intent, operation_id: SecureRandom.uuid,
                                   state: "pending", generation: 1)
    InvoiceOperationIntent.create!(company_id: company.id, invoice_id: failed_intent, operation_id: SecureRandom.uuid,
                                   state: "failed", generation: 1)
    InvoiceOperationIntent.create!(company_id: other_company.id, invoice_id: foreign_intent,
                                   operation_id: SecureRandom.uuid, state: "pending", generation: 1)

    ids = described_class.ids(company_id: company.id,
                              invoice_ids: [kept, discarded, foreign, pending_intent, failed_intent, foreign_intent, unknown])

    expect(ids).to contain_exactly(kept, discarded, pending_intent, failed_intent)
    expect(described_class.ids(company_id: company.id, invoice_ids: [])).to eq([])
  end
  end
end

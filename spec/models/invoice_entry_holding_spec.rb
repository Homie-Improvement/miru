# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceEntryHolding, type: :model do
  def holding_attributes(**overrides)
    { company_id: 1, invoice_id: 10, entry_ids: [1, 2], disposition: "active", updated_at: Time.current }.merge(overrides)
  end

  it "accepts active and retained and rejects another disposition in the model and in the database" do
    %w[active retained].each do |disposition|
      expect(described_class.new(holding_attributes(disposition:))).to be_valid
    end

    expect(described_class.new(holding_attributes(disposition: "deleted"))).not_to be_valid
    expect { described_class.insert_all([holding_attributes(disposition: "deleted")]) }
      .to raise_error(ActiveRecord::StatementInvalid, /disposition_check/)
  end

  it "requires company_id in the database" do
    expect { described_class.insert_all([holding_attributes(company_id: nil)]) }
      .to raise_error(ActiveRecord::NotNullViolation)
  end

  it "refuses a second holding for one invoice of one company, and allows the same invoice_id in another company" do
    described_class.insert_all([holding_attributes])
    described_class.insert_all([holding_attributes(company_id: 2)])

    expect(described_class.where(invoice_id: 10).pluck(:company_id)).to contain_exactly(1, 2)
    expect { described_class.insert_all!([holding_attributes]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "defaults to no entries, active" do
    holding = described_class.create!(company_id: 1, invoice_id: 10)

    expect(holding.reload.entry_ids).to eq([])
    expect(holding.disposition).to eq("active")
  end

  it "keeps the holding after its invoice is destroyed" do
    invoice = create(:invoice)
    holding = described_class.create!(company_id: invoice.company_id, invoice_id: invoice.id, entry_ids: [5])

    invoice.destroy!

    expect(described_class.find(holding.id).entry_ids).to eq([5])
  end
end

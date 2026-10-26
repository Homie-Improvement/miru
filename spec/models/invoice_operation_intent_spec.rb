# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceOperationIntent, type: :model do
  def intent_attributes(**overrides)
    { company_id: 1, invoice_id: 10, operation_id: SecureRandom.uuid, state: "pending", generation: 1 }.merge(overrides)
  end

  it "stores an intent for an invoice that does not exist, so it outlives a deleted invoice" do
    intent = described_class.create!(intent_attributes(invoice_id: Invoice.maximum(:id).to_i + 1_000))

    expect(intent.reload.state).to eq("pending")
  end

  it "accepts each of pending, committed and failed" do
    %w[pending committed failed].each do |state|
      expect(described_class.new(intent_attributes(state:))).to be_valid
    end
  end

  it "rejects another state in the model and in the database" do
    expect(described_class.new(intent_attributes(state: "aborted"))).not_to be_valid
    expect { described_class.insert_all([intent_attributes(state: "aborted", created_at: Time.current)]) }
      .to raise_error(ActiveRecord::StatementInvalid, /state_check/)
  end

  it "requires company_id in the database" do
    expect { described_class.insert_all([intent_attributes(company_id: nil, created_at: Time.current)]) }
      .to raise_error(ActiveRecord::NotNullViolation)
  end

  it "defaults the stored request to no entries, active" do
    intent = described_class.create!(intent_attributes)

    expect(intent.reload.desired_entry_ids).to eq([])
    expect(intent.disposition).to eq("active")
  end

  it "stores the request's entries and accepts active and retained" do
    %w[active retained].each do |disposition|
      intent = described_class.create!(intent_attributes(desired_entry_ids: [3, 7], disposition:))

      expect(intent.reload.desired_entry_ids).to eq([3, 7])
    end
  end

  it "rejects another disposition in the model and in the database" do
    expect(described_class.new(intent_attributes(disposition: "deleted"))).not_to be_valid
    expect { described_class.insert_all([intent_attributes(disposition: "deleted", created_at: Time.current)]) }
      .to raise_error(ActiveRecord::StatementInvalid, /disposition_check/)
  end

  it "refuses the same operation twice for one invoice" do
    attributes = intent_attributes
    described_class.create!(attributes)

    expect { described_class.create!(attributes) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end

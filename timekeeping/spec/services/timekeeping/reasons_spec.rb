# frozen_string_literal: true

require "rails_helper"

# The service deploys without the contracts directory, so its status map is
# written out in app code; this spec keeps it equal to the contract YAML.
RSpec.describe Timekeeping::Reasons do
  service_only_reasons = {
    reference_unavailable: 503, idempotency_key_required: 422, invalid_request: 400,
    handoff_refused: 409, fence_timeout: 503, admission_missing: 409, unpublishable_entry: 409
  }.freeze

  def contract_errors(name)
    YAML.safe_load_file(Rails.root.join("../contracts/timekeeping/#{name}.yml")).fetch("errors").values
  end

  let(:contract_statuses) do
    (contract_errors(:entry_api) + contract_errors(:idempotency)).to_h do |error|
      [error.fetch("body").fetch("reason").to_sym, error.fetch("status")]
    end
  end

  it "gives every entry API and idempotency contract reason its contract status" do
    expect(described_class::STATUS.slice(*contract_statuses.keys)).to eq(contract_statuses)
  end

  # reservations.yml gives most reasons in a body, and conflict and
  # unresolved_operation as a reason beside the body's field list.
  let(:reservation_statuses) do
    contract_errors(:reservations).to_h do |error|
      [(error.dig("body", "reason") || error.fetch("reason")).to_sym, error.fetch("status")]
    end
  end

  it "gives every reservation contract reason its contract status" do
    expect(described_class::STATUS.slice(*reservation_statuses.keys)).to eq(reservation_statuses)
  end

  it "adds only the service's own reasons beyond the contract" do
    expect(described_class::STATUS.except(*contract_statuses.keys, *reservation_statuses.keys))
      .to eq(service_only_reasons)
  end

  it "answers a reason given as a symbol or a string" do
    expect([described_class.status(:stale_generation), described_class.status("reference_unavailable")]).to eq([409, 503])
  end

  it "raises for a reason it does not know" do
    expect { described_class.status(:teapot) }.to raise_error(KeyError)
  end
end

# frozen_string_literal: true

require "rails_helper"
require_relative "../../contracts/timekeeping/prepare_reconciliation_examples"

RSpec.describe Invoices::SaveReconciliation do
  it "settles only committed+committed and aborted+failed, and answers every other pair, including prepared and nil, as retryable reconciliation_error" do
    # "Decide the result from the remote state and the intent state through the contract's `save_reconciliation` table: remote committed with intent committed → existing_success; remote aborted with intent failed → save_failed; any other pair → retryable reconciliation_error."
    expect(described_class.call(remote_state: "committed", intent_state: "committed"))
      .to eq("outcome" => "existing_success", "retryable" => false, "changed" => false)
    expect(described_class.call(remote_state: "aborted", intent_state: "failed"))
      .to eq("outcome" => "save_failed", "retryable" => false, "changed" => false)

    # "HTTP 200 alone is never success."
    fallback = { "outcome" => "reconciliation_error", "retryable" => true, "changed" => false }
    [
      %w[committed failed], %w[committed pending], %w[aborted committed], %w[aborted pending],
      %w[prepared committed], %w[prepared pending], %w[retryable committed], [nil, "committed"], ["committed", nil]
    ].each do |remote_state, intent_state|
      expect(described_class.call(remote_state:, intent_state:)).to eq(fallback),
        "expected #{remote_state.inspect}/#{intent_state.inspect} to take the retryable fallback"
    end
  end
end

RSpec.describe Invoices::SaveReconciliation do
  it "maps the issue's two settled pairs to their outcomes and every mismatched pair to the retryable reconciliation_error" do
    # "remote committed with intent committed → existing_success; remote aborted with intent failed → save_failed; any other pair → retryable reconciliation_error."
    expect(described_class.call(remote_state: "committed", intent_state: "committed"))
      .to eq("outcome" => "existing_success", "retryable" => false, "changed" => false)
    expect(described_class.call(remote_state: "aborted", intent_state: "failed"))
      .to eq("outcome" => "save_failed", "retryable" => false, "changed" => false)

    fallback = { "outcome" => "reconciliation_error", "retryable" => true, "changed" => false }
    [%w[committed failed], %w[committed pending], %w[aborted committed], %w[aborted pending]].each do |remote_state, intent_state|
      expect([remote_state, intent_state, described_class.call(remote_state:, intent_state:)])
        .to eq([remote_state, intent_state, fallback])
    end
  end
end

RSpec.describe Invoices::SaveReconciliation do
  it "answers the retryable reconciliation_error for a remote prepared state and for missing states" do
    fallback = { "outcome" => "reconciliation_error", "retryable" => true, "changed" => false }

    # The client's commit can answer the replayed state "prepared", which the table does not list.
    expect(described_class.call(remote_state: "prepared", intent_state: "committed")).to eq(fallback)
    expect(described_class.call(remote_state: "retryable", intent_state: "failed")).to eq(fallback)
    expect(described_class.call(remote_state: nil, intent_state: nil)).to eq(fallback)
  end
end

RSpec.describe Invoices::SaveReconciliation do
  let(:reconciler) { described_class }

  it_behaves_like "timekeeping prepare reconciliation"
end

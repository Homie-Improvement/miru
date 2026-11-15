# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoices::ReservationBoundary, "mark_billed decision" do
  it "mark_billed raises a retryable error with the reason for every answer that is not committed or refused" do
    invoice = create(:invoice)
    answers = {
      "committed" => Invoices::ReservationOutcome.new(state: "committed", conflicts: [], counts: { billed: 0 }),
      "retryable" => Invoices::ReservationOutcome.new(state: "retryable", conflicts: [], counts: {}, reason: "stale_generation"),
      "prepared" => Invoices::ReservationOutcome.new(state: "prepared", conflicts: [], counts: {}),
      "refused" => Invoices::ReservationOutcome.new(state: "refused", conflicts: [{ entry_id: 3, reason: "on_another_invoice" }], counts: {})
    }
    adapter = Object.new
    current = nil
    adapter.define_singleton_method(:mark_billed) { |_request| answers.fetch(current) }
    allow(Invoices::ReservationAdapters).to receive(:for).and_return(adapter)

    # "Make it decide from a table: `committed` returns, `refused` raises `OperationErrors::Refused`, and every other state raises `OperationErrors::PrepareRetryable` with the reason."
    current = "committed"
    expect(described_class.mark_billed(invoice).state).to eq("committed")

    current = "retryable"
    expect { described_class.mark_billed(invoice) }
      .to raise_error(Invoices::OperationErrors::PrepareRetryable, "stale_generation")

    current = "prepared"
    expect { described_class.mark_billed(invoice) }.to raise_error(Invoices::OperationErrors::PrepareRetryable)

    current = "refused"
    expect { described_class.mark_billed(invoice) }.to raise_error(Invoices::OperationErrors::Refused)
  end
end

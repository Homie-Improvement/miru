# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoices::EntryReferenceCheck do
  it "legacy and rollback keep the projection check while the timekeeping owner checks the prepare response" do
    # "The legacy and rollback states keep today's invoice validation behaviour, and the 12.1 invoice specs still pass in all three states"
    expect(described_class.source_for(:legacy)).to eq(:projection)
    expect(described_class.source_for(:prepared)).to eq(:projection)
    expect(described_class.source_for(:timekeeping)).to eq(:prepare_response)
    expect { described_class.source_for(:unknown) }.to raise_error(StandardError)
  end
end

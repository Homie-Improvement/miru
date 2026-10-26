# frozen_string_literal: true

require "rails_helper"

# The service deploys without the contracts directory, so the outbox row's
# field list is written out in app code; this spec keeps it equal to the
# contract.
RSpec.describe Timekeeping::OutboxFields do
  let(:contract_fields) do
    YAML.safe_load_file(Rails.root.join("../contracts/timekeeping/entry_snapshots.yml")).fetch("entry_fields")
  end

  it "lists exactly the entry_snapshots.yml entry fields" do
    expect(described_class::ENTRY_FIELDS).to eq(contract_fields)
  end

  it "adds only generation and outbox_position for a row" do
    expect(described_class::ROW_FIELDS).to eq(contract_fields + %w[generation outbox_position])
  end

  it "matches the table's columns with the relay's bookkeeping added" do
    expect(described_class::RELAY_FIELDS).to eq(%w[enqueued_at sent_at])
    expect(OutboxSnapshot.column_names).to match_array(described_class::ROW_FIELDS + described_class::RELAY_FIELDS)
  end
end

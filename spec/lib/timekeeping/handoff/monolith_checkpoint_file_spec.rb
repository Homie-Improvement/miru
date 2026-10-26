# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Handoff::MonolithStore, :without_transaction do
  # Timekeeping's suite loads the checked-in file through its own load route,
  # so the file must be exactly what this store exports.
  it "exports the seeded two-company rows as exactly the checked-in checkpoint file" do
    connection = ActiveRecord::Base.connection
    connection.execute(MonolithCheckpointFileSeed::SQL)

    exported = described_class.new(connection:).export_checkpoint

    %w[entries reservations invoice_operations entry_audits idempotency_records].each do |table|
      expect(exported.digest.fetch(table).keys).to contain_exactly(1, 2)
    end
    expect(exported.to_json).to eq(MonolithCheckpointFileSeed::FILE.read.chomp)
  end
end

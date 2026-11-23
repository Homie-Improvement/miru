# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"
require_relative "../../../spec/support/timekeeping/contract"
require_relative "../../../spec/support/timekeeping/client"
require_relative "../../../spec/contracts/timekeeping/reservations_examples"
require_relative "../../../spec/contracts/timekeeping/idempotency_examples"

# Runs the monolith's shared reservation and idempotency examples, unchanged,
# against the real Timekeeping app.
RSpec.describe "Timekeeping reservations provider" do
  include_context "timekeeping entry writes"

  let(:timekeeping_client) { TimekeepingRackClient.new(Rails.application) }

  it_behaves_like "timekeeping reservations contract"
  it_behaves_like "timekeeping idempotency contract", contracts: [:reservations]
end

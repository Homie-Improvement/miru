# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"
require_relative "../../../spec/support/timekeeping/contract"
require_relative "../../../spec/support/timekeeping/client"
require_relative "../../../spec/contracts/timekeeping/entry_api_examples"
require_relative "../../../spec/contracts/timekeeping/idempotency_examples"
require_relative "../../../spec/contracts/timekeeping/entry_replay_examples"

# Runs the monolith's shared entry API, idempotency and replay-only delete
# examples, unchanged, against the real Timekeeping app.
RSpec.describe "Timekeeping entry API provider" do
  include_context "timekeeping entry writes"

  let(:timekeeping_client) { TimekeepingRackClient.new(Rails.application) }

  it_behaves_like "timekeeping entry API contract"
  it_behaves_like "timekeeping idempotency contract", contracts: [:entry_api]
  it_behaves_like "timekeeping entry replay contract"
end

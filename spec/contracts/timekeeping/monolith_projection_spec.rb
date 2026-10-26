# frozen_string_literal: true

require "rails_helper"
require_relative "entry_snapshot_examples"
require_relative "idempotency_examples"

# Runs the snapshot contract groups against the monolith's real projection
# endpoint, POST /internal/v1/timekeeping/entry-snapshots.
RSpec.describe "The monolith's entry snapshot endpoint under the Timekeeping contracts" do
  # These examples need service identities the monolith does not have. It
  # accepts one token, TIMEKEEPING_SERVICE_TOKEN, bound to no company, and
  # answers 401 to every other credential, user tokens included; the request
  # specs under spec/requests/internal/v1/timekeeping prove those refusals.
  unreproducible_identity_examples = {
    "refuses a caller without the Timekeeping service identity and applies nothing" =>
      "the contract expects 403 for a user token and a service without deliver; the monolith answers 401",
    "refuses a service bound to one company that delivers another company's snapshots" =>
      "the monolith has no company-bound service identity",
    "does not match the same key and batch from another service" =>
      "the monolith has a single service identity, so no second relay exists"
  }.freeze

  let(:timekeeping_client) { TimekeepingContract::MonolithClient.new }
  let(:timekeeping_arrange) { TimekeepingContract::MonolithArrange.new(private_key: timekeeping_key_pair) }

  around do |example|
    with_timekeeping_service_token { example.run }
  end

  before do |example|
    reason = unreproducible_identity_examples[example.description]
    skip(reason) if reason
  end

  describe "the snapshot endpoint" do
    it_behaves_like "timekeeping entry snapshot endpoint"
  end

  describe "the idempotency contract for snapshot deliveries" do
    it_behaves_like "timekeeping idempotency contract", contracts: [:entry_snapshots]
  end
end

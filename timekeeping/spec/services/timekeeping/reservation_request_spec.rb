# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReservationRequest do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:token) do
    timekeeping_arrange.service_identity(company:, name: "invoice-boundary",
                                         operations: %w[prepare commit abort mark_billed detach_entries])
  end
  let(:identity) do
    Timekeeping::Identity.resolve(authorization: "Bearer #{token}", public_key: Timekeeping::Environment.token_public_key,
                                  service_token: provider_service_token)
  end
  let(:operation_id) { SecureRandom.uuid }

  def build_request(route, body, path_id: nil)
    described_class.build(route:, identity:, path_id:, raw_body: JSON.generate(body), bearer: token)
  end

  def prepare_body(**fields)
    { "invoice_id" => 501, "operation_id" => operation_id, "generation" => 1, "disposition" => "active",
      "entries" => [11, 12] }.merge(fields.transform_keys(&:to_s))
  end

  it "builds a prepare request from the verified service and the checked body" do
    request = build_request(:prepare, prepare_body)

    expect(request).to eq(Timekeeping::ReservationOperations::Request.new(
      route: :prepare, company_id: company, actor_name: "invoice-boundary", invoice_id: 501, operation_id:,
      generation: 1, disposition: "active", entry_ids: [11, 12]
    ))
    expect(described_class.handler(:prepare)).to eq(Timekeeping::ReservationOperations)
  end

  it "builds a mark-billed request whose target is the path's invoice" do
    request = build_request(:mark_billed, { "operation_id" => operation_id, "generation" => 1 }, path_id: "501")

    expect(request).to eq(Timekeeping::ServiceCommands::Request.new(
      route: :mark_billed, company_id: company, actor_name: "invoice-boundary", target_id: 501, operation_id:,
      generation: 1
    ))
    expect(described_class.handler(:mark_billed)).to eq(Timekeeping::ServiceCommands)
  end

  it "refuses an entry listed twice, a non-uuid operation id and an id beyond bigint as a bad request" do
    [
      [:prepare, prepare_body(entries: [11, 11])],
      [:prepare, prepare_body(operation_id: "op-1")],
      [:prepare, prepare_body(disposition: "kept")],
      [:prepare, prepare_body(entries: [2**63])],
      [:commit, { "invoice_id" => "501", "operation_id" => operation_id }],
      [:abort, { "operation_id" => operation_id }]
    ].each do |route, body|
      expect { build_request(route, body) }.to raise_error(ActionController::BadRequest)
    end
  end

  it "answers a path id that cannot name a row as not found" do
    %w[abc 9223372036854775808 0].each do |path_id|
      outcome = build_request(:detach_entries, { "operation_id" => operation_id }, path_id:)

      expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
    end
  end

  it "refuses a body carrying the caller's own token or another service token before checking its shape" do
    other = timekeeping_arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])

    [token, other].each do |credential|
      outcome = build_request(:prepare, { "operation_id" => "not-a-uuid", "note" => "see #{credential}" })

      expect([outcome.status, JSON.parse(outcome.body)]).to eq([422, { "reason" => "credential_in_body" }])
    end
  end
end

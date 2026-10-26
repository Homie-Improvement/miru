# frozen_string_literal: true

require "rails_helper"

# Every handoff endpoint answers 401 to a caller that does not hold the
# service token, and changes nothing.
RSpec.describe "Timekeeping internal handoff refusals for callers without the service token" do
  let(:refusal_service_token) { "service-#{SecureRandom.hex(24)}" }
  let(:refusal_callers) do
    [
      nil,
      "Bearer #{refusal_service_token}x",
      "Bearer #{mint_token({ sub: 7, company_id: 1, role: 'owner' })}"
    ]
  end

  around do |example|
    with_timekeeping_env(
      Timekeeping::Environment::TOKEN_PUBLIC_KEY => rsa_key_pair.public_key.to_pem,
      Timekeeping::Environment::SERVICE_TOKEN => refusal_service_token
    ) { example.run }
  end

  def refusal_state
    [Entry.count, OutboxSnapshot.count, AuditEvent.count, IdempotencyReceipt.count,
     Timekeeping::Admission.current.generation]
  end

  def refusal_answers(verb, path, body)
    refusal_callers.map do |authorization|
      headers = { "Content-Type" => "application/json" }
      headers["Authorization"] = authorization if authorization
      public_send(verb, path, params: body, headers:)
      [response.status, response.parsed_body]
    end
  end

  before do
    Timekeeping::Admission.ensure_initial!
    Timekeeping::Admission.admit!(generation: 1)
  end

  [
    [:get, "/internal/v1/handoff/checkpoint", nil],
    [:put, "/internal/v1/handoff/checkpoint", "{}"],
    [:post, "/internal/v1/handoff/entry_id_sequence", { above: 500 }.to_json],
    [:get, "/internal/v1/handoff/outbox_position", nil],
    [:post, "/internal/v1/handoff/admission/fence", nil],
    [:post, "/internal/v1/handoff/admission/admit", { generation: 7 }.to_json]
  ].each do |verb, path, body|
    it "answers 401 to #{verb.upcase} #{path} without the service token and changes nothing" do
      before_state = refusal_state

      expect(refusal_answers(verb, path, body)).to all(eq([401, { "reason" => "unauthorized" }]))
      expect(refusal_state).to eq(before_state)
    end
  end

  it "answers 401 to a complete correction without the service token and writes no snapshot" do
    entry = Entry.create!(company_id: 1, user_id: 1, project_id: 2, work_date: "2026-03-02", duration: 30.0,
                          note: "", bill_status: "unbilled", source: "manual", source_metadata: {})
    snapshot = entry.attributes.slice(*(Timekeeping::OutboxFields::ENTRY_FIELDS - ["version"])).merge("locked" => true)
    body = { generation: 2, version: 1, snapshots: [snapshot] }.to_json
    before_state = refusal_state
    stored_version = entry.version

    expect(refusal_answers(:put, "/internal/v1/handoff/correction_snapshots", body))
      .to all(eq([401, { "reason" => "unauthorized" }]))
    expect(refusal_state).to eq(before_state)
    expect(entry.reload.version).to eq(stored_version)
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /internal/v1/handoff/stop_applying refusals" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  # "Each of the three routes answers 401 with no bearer and refuses a near-miss token and a user token.
  # The admission row, invoice_operations and outbox_snapshots stay unchanged."
  it "stop_applying refuses no bearer, a near-miss service token and user tokens with 401 and leaves the open settle step in place" do
    Timekeeping::Admission.fence!
    Timekeeping::Admission.begin_settling!(generation: 4)
    admission_before = Timekeeping::Admission.current.attributes
    rows_before = handoff_stored_rows
    expect(Timekeeping::Admission.settling?).to be(true)

    callers = {
      "no bearer" => nil,
      "near-miss service token" => "Bearer #{handoff_service_token}x",
      "owner token" => "Bearer #{mint_token({ sub: 7, company_id: 1, role: 'owner' })}",
      "employee token" => "Bearer #{mint_token}"
    }
    callers.each do |caller_name, authorization|
      headers = { "Content-Type" => "application/json" }
      headers["Authorization"] = authorization if authorization
      post "/internal/v1/handoff/stop_applying", params: JSON.generate("generation" => 4), headers: headers

      expect([caller_name, response.status, response.parsed_body]).to eq([caller_name, 401, { "reason" => "unauthorized" }])
      expect([caller_name, Timekeeping::Admission.current.attributes]).to eq([caller_name, admission_before])
      expect([caller_name, handoff_stored_rows]).to eq([caller_name, rows_before])
    end
    expect(Timekeeping::Admission.settling?).to be(true)
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /internal/v1/handoff/settle with a malformed generation" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or
  # non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
  it "settle refuses a missing, zero, negative, string or fractional generation with invalid_request and opens no settle step" do
    Timekeeping::Admission.fence!
    admission_before = Timekeeping::Admission.current.attributes
    rows_before = handoff_stored_rows
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }

    bodies = {
      "missing" => "{}",
      "zero" => '{"generation":0}',
      "negative" => '{"generation":-1}',
      "string" => '{"generation":"4"}',
      "fraction" => '{"generation":4.5}',
      "null" => '{"generation":null}',
      "too large" => %({"generation":#{2**64}})
    }
    bodies.each do |label, body|
      post "/internal/v1/handoff/settle", params: body, headers: headers

      expect([label, response.status, response.parsed_body]).to eq([label, 400, { "reason" => "invalid_request" }])
      expect([label, Timekeeping::Admission.current.attributes]).to eq([label, admission_before])
      expect([label, handoff_stored_rows]).to eq([label, rows_before])
    end
    expect(Timekeeping::Admission.settling?).to be(false)
  end
end

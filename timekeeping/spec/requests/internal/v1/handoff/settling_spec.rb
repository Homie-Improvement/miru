# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping internal handoff settle refuses callers without the service token" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  # "The admission row, invoice_operations and outbox_snapshots stay unchanged."
  it "a settle request without the service token gets 401" do
    Timekeeping::Admission.fence!
    state = lambda do
      handoff_stored_rows.merge(
        "admission" => ApplicationRecord.connection.select_rows("SELECT * FROM admission ORDER BY 1")
      )
    end
    baseline = state.call
    callers = {
      "no bearer" => nil,
      "near-miss service token" => "Bearer #{handoff_service_token}x",
      "employee token" => "Bearer #{mint_token}",
      "owner token" => "Bearer #{mint_token({ sub: 7, company_id: 1, role: 'owner' })}"
    }

    callers.each do |caller_name, authorization|
      headers = { "Content-Type" => "application/json" }
      headers["Authorization"] = authorization if authorization
      # Generation 4 would open settling on the fenced row if the request got through.
      post "/internal/v1/handoff/settle", params: JSON.generate(generation: 4), headers: headers

      expect([caller_name, response.status, response.parsed_body]).to eq([caller_name, 401, { "reason" => "unauthorized" }])
      expect([caller_name, state.call]).to eq([caller_name, baseline])
    end
    expect(Timekeeping::Admission.settling?).to be(false)
  end
end

RSpec.describe "Timekeeping internal handoff stop_applying and drain refuse callers without the service token" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  # "Each of the three routes answers 401 with no bearer and refuses a near-miss token and a user token.
  # The admission row, invoice_operations and outbox_snapshots stay unchanged."
  it "a stop_applying or drain request without the service token gets 401 and changes no stored row" do
    Timekeeping::Admission.fence!
    Timekeeping::Admission.begin_settling!(generation: 4)
    state = lambda do
      handoff_stored_rows.merge(
        "admission" => ApplicationRecord.connection.select_rows("SELECT * FROM admission ORDER BY 1")
      )
    end
    baseline = state.call
    callers = {
      "no bearer" => nil,
      "near-miss service token" => "Bearer #{handoff_service_token}x",
      "admin token" => "Bearer #{mint_token({ sub: 7, company_id: 1, role: 'admin' })}",
      "employee token" => "Bearer #{mint_token}"
    }
    # A stop for generation 4 would close the open settle step if it got through.
    requests = {
      "/internal/v1/handoff/stop_applying" => { generation: 4 },
      "/internal/v1/handoff/drain" => { through: 0 }
    }

    requests.each do |path, body|
      callers.each do |caller_name, authorization|
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = authorization if authorization
        post path, params: JSON.generate(body), headers: headers

        expect([path, caller_name, response.status, response.parsed_body])
          .to eq([path, caller_name, 401, { "reason" => "unauthorized" }])
        expect([path, caller_name, state.call]).to eq([path, caller_name, baseline])
      end
    end
    expect(Timekeeping::Admission.settling?).to be(true)
  end
end

RSpec.describe "Timekeeping internal handoff settle and stop_applying refuse a malformed generation" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or
  # non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
  it "a settle or stop_applying request with a malformed generation is refused with invalid_request and changes nothing" do
    Timekeeping::Admission.fence!
    state = lambda do
      handoff_stored_rows.merge(
        "admission" => ApplicationRecord.connection.select_rows("SELECT * FROM admission ORDER BY 1")
      )
    end
    baseline = state.call
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    bodies = {
      "missing" => "{}",
      "string" => JSON.generate(generation: "4"),
      "float" => '{"generation": 4.5}',
      "integral float" => '{"generation": 4.0}',
      "zero" => JSON.generate(generation: 0),
      "negative" => JSON.generate(generation: -1),
      "boolean" => JSON.generate(generation: true),
      "null" => JSON.generate(generation: nil),
      "too large" => JSON.generate(generation: 2**64),
      "not an object" => "[4]"
    }

    %w[/internal/v1/handoff/settle /internal/v1/handoff/stop_applying].each do |path|
      bodies.each do |row, body|
        post path, params: body, headers: headers

        expect([path, row, response.status, response.parsed_body])
          .to eq([path, row, 400, { "reason" => "invalid_request" }])
        expect([path, row, state.call]).to eq([path, row, baseline])
      end
    end
  end
end

RSpec.describe "Timekeeping internal handoff settle and stop_applying persistence" do
  include_context "timekeeping entry writes without transactional fixtures"

  around do |example|
    with_handoff_env(public_key: true) { example.run }
  end

  def settling_persistence_post(path, body)
    post path, params: JSON.generate(body),
               headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    [response.status, response.parsed_body]
  end

  def settling_persistence_state
    admission = Timekeeping::Admission.current
    admission.reload
    handoff_stored_rows.merge(
      "admission" => admission.attributes.slice("generation", "settling_generation", "settling_stopped_generation")
    )
  end

  # "A repeated identical request leaves the same state."
  it "a repeated identical settle request leaves the same admission state and gives the same answer" do
    Timekeeping::Admission.fence!

    first = settling_persistence_post("/internal/v1/handoff/settle", { generation: 4 })
    after_first = settling_persistence_state
    second = settling_persistence_post("/internal/v1/handoff/settle", { generation: 4 })

    expect(first).to eq([200, { "settling" => true, "prepared_operations" => 0 }])
    expect(after_first["admission"]).to eq(
      "generation" => nil, "settling_generation" => 4, "settling_stopped_generation" => nil
    )
    expect(second).to eq(first)
    expect(settling_persistence_state).to eq(after_first)
  end
end

RSpec.describe "Timekeeping internal handoff stop_applying persistence" do
  include_context "timekeeping entry writes without transactional fixtures"

  around do |example|
    with_handoff_env(public_key: true) { example.run }
  end

  def stop_applying_persistence_post(path, body)
    post path, params: JSON.generate(body),
               headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    response.status
  end

  def stop_applying_persistence_state
    admission = Timekeeping::Admission.current
    admission.reload
    admission.attributes.slice("generation", "settling_generation", "settling_stopped_generation")
  end

  it "a stop_applying for an older generation than the one settling changes nothing, and a repeated stop leaves the same state" do
    Timekeeping::Admission.fence!
    expect(stop_applying_persistence_post("/internal/v1/handoff/settle", { generation: 5 })).to eq(200)
    settling = stop_applying_persistence_state
    expect(settling).to eq("generation" => nil, "settling_generation" => 5, "settling_stopped_generation" => nil)

    # "A stop for an older generation than the one settling changes nothing."
    expect(stop_applying_persistence_post("/internal/v1/handoff/stop_applying", { generation: 4 })).to eq(200)
    expect(stop_applying_persistence_state).to eq(settling)

    # "A repeated identical request leaves the same state."
    expect(stop_applying_persistence_post("/internal/v1/handoff/stop_applying", { generation: 5 })).to eq(200)
    stopped = stop_applying_persistence_state
    expect(stopped).to eq("generation" => nil, "settling_generation" => nil, "settling_stopped_generation" => 5)
    expect(stop_applying_persistence_post("/internal/v1/handoff/stop_applying", { generation: 5 })).to eq(200)
    expect(stop_applying_persistence_state).to eq(stopped)
  end
end

RSpec.describe "Timekeeping internal handoff malformed generation refusals" do
  include_context "timekeeping entry writes without transactional fixtures"

  around do |example|
    with_handoff_env(public_key: true) { example.run }
  end

  def malformed_generation_post(path, body)
    params = body.is_a?(String) ? body : JSON.generate(body)
    post path, params:,
               headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    [response.status, response.parsed_body]
  end

  def malformed_generation_state
    admission = Timekeeping::Admission.current
    admission.reload
    handoff_stored_rows.merge(
      "admission" => admission.attributes.slice("generation", "settling_generation", "settling_stopped_generation")
    )
  end

  # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or
  # non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
  it "malformed settle and stop_applying generations are refused with invalid_request and leave the settling columns unchanged" do
    Timekeeping::Admission.fence!
    baseline = malformed_generation_state
    bodies = {
      "missing" => {}, "zero" => { generation: 0 }, "negative" => { generation: -1 },
      "string" => { generation: "4" }, "float" => '{"generation": 4.5}', "null" => { generation: nil },
      "boolean" => { generation: true }, "beyond bigint" => { generation: 2**64 }
    }

    %w[/internal/v1/handoff/settle /internal/v1/handoff/stop_applying].each do |path|
      bodies.each do |label, body|
        answer = malformed_generation_post(path, body)

        expect([path, label, answer]).to eq([path, label, [400, { "reason" => "invalid_request" }]])
        expect([path, label, malformed_generation_state]).to eq([path, label, baseline])
      end
    end
  end
end

RSpec.describe "Timekeeping internal handoff settle" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  it "settle while fenced opens settling at the given generation and counts only prepared invoice operations" do
    Timekeeping::Admission.fence!
    { 41 => "prepared", 42 => "prepared", 43 => "committed", 44 => "aborted" }.each do |invoice_id, state|
      InvoiceOperation.create!(company_id: 1, invoice_id:, operation_id: SecureRandom.uuid, actor_name: "invoice-service",
                               state:, desired_entry_ids: [], disposition: "active", generation: 3,
                               finished_at: state == "prepared" ? nil : Time.current)
    end

    # "It calls `Timekeeping::Admission.begin_settling!(generation:)` and answers 200 with `settling` and
    # `prepared_operations`, the count of Timekeeping invoice_operations still 'prepared'."
    post "/internal/v1/handoff/settle", params: JSON.generate("generation" => 3),
                                        headers: { "Content-Type" => "application/json",
                                                   "Authorization" => "Bearer #{handoff_service_token}" }

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("settling" => true, "prepared_operations" => 2)
    expect(Timekeeping::Admission.settling?).to be(true)
    expect(Timekeeping::Admission.current.settling_generation).to eq(3)
  end
end

RSpec.describe "Timekeeping internal handoff settle on an admitted row" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  it "settle while writes are admitted answers settling false and leaves the admission row unchanged" do
    Timekeeping::Admission.admit!(generation: 3)
    before_row = Timekeeping::Admission.current.attributes

    post "/internal/v1/handoff/settle", params: JSON.generate("generation" => 3),
                                        headers: { "Content-Type" => "application/json",
                                                   "Authorization" => "Bearer #{handoff_service_token}" }

    # The settling answer is read back from the stored row, so a no-op begin_settling! answers false.
    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("settling" => false, "prepared_operations" => 0)
    expect(Timekeeping::Admission.current.attributes).to eq(before_row)
  end
end

RSpec.describe "Timekeeping internal handoff settle repeated" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  it "a repeated identical settle request gives the same answer and leaves the same admission state" do
    Timekeeping::Admission.fence!
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }

    # "A repeated identical request leaves the same state."
    post "/internal/v1/handoff/settle", params: JSON.generate("generation" => 6), headers: headers
    first = [response.status, response.parsed_body, Timekeeping::Admission.current.attributes, handoff_stored_rows]

    post "/internal/v1/handoff/settle", params: JSON.generate("generation" => 6), headers: headers
    second = [response.status, response.parsed_body, Timekeeping::Admission.current.attributes, handoff_stored_rows]

    expect(first[0..1]).to eq([200, { "settling" => true, "prepared_operations" => 0 }])
    expect(second).to eq(first)
  end
end

RSpec.describe "Timekeeping internal handoff settle with a malformed generation" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  it "settle refuses a missing, zero, negative, string, decimal or null generation with invalid_request and opens no settling" do
    Timekeeping::Admission.fence!
    baseline = [Timekeeping::Admission.current.attributes, handoff_stored_rows]
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }

    # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or
    # non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
    ["{}", '{"generation":0}', '{"generation":-1}', '{"generation":"3"}', '{"generation":3.5}',
     '{"generation":null}'].each do |body|
      post "/internal/v1/handoff/settle", params: body, headers: headers

      expect([body, response.status, response.parsed_body]).to eq([body, 400, { "reason" => "invalid_request" }])
      expect([body, Timekeeping::Admission.current.attributes, handoff_stored_rows]).to eq([body, *baseline])
    end
  end
end

RSpec.describe "Timekeeping internal handoff stop_applying" do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: true) { example.run } }

  it "stop_applying for an older generation than the one settling leaves settling open and the row unchanged" do
    Timekeeping::Admission.fence!
    Timekeeping::Admission.begin_settling!(generation: 5)
    before_row = Timekeeping::Admission.current.attributes
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }

    # "A stop for an older generation than the one settling changes nothing."
    post "/internal/v1/handoff/stop_applying", params: JSON.generate("generation" => 4), headers: headers

    expect(response.status).to eq(200)
    expect(Timekeeping::Admission.current.attributes).to eq(before_row)
    expect(Timekeeping::Admission.settling?).to be(true)

    post "/internal/v1/handoff/stop_applying", params: JSON.generate("generation" => 5), headers: headers

    expect(response.status).to eq(200)
    expect(Timekeeping::Admission.settling?).to be(false)
    expect(Timekeeping::Admission.current.settling_stopped_generation).to eq(5)
  end
end

RSpec.describe "POST /internal/v1/handoff/settle after the step was stopped", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  def settling_late_settle_state
    Timekeeping::Admission.current.attributes.slice("generation", "settling_generation", "settling_stopped_generation")
  end

  def settling_late_settle_post(path, generation)
    post path, params: JSON.generate(generation:),
               headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
  end

  # "A repeated identical request leaves the same state."
  # A retried settle that arrives after the stop must not tell the runner settling began again.
  it "a settle repeated after stop_applying for the same generation answers settling false and does not reopen the step" do
    Timekeeping::Admission.fence!
    settling_late_settle_post("/internal/v1/handoff/settle", 5)
    expect(response.parsed_body).to include("settling" => true)
    settling_late_settle_post("/internal/v1/handoff/stop_applying", 5)
    expect(response).to have_http_status(:ok)
    stopped_state = settling_late_settle_state

    settling_late_settle_post("/internal/v1/handoff/settle", 5)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("settling" => false)
    expect(settling_late_settle_state).to eq(stopped_state)
    expect(stopped_state).to eq("generation" => nil, "settling_generation" => nil, "settling_stopped_generation" => 5)
  end
end

RSpec.describe "POST /internal/v1/handoff/stop_applying for an older generation", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  def settling_older_stop_state
    Timekeeping::Admission.current.attributes.slice("generation", "settling_generation", "settling_stopped_generation")
  end

  def settling_older_stop_post(path, generation)
    post path, params: JSON.generate(generation:),
               headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
  end

  # "A stop for an older generation than the one settling changes nothing."
  it "a late stop_applying for an older generation leaves the newer settling step open and the stop mark unchanged" do
    Timekeeping::Admission.fence!
    settling_older_stop_post("/internal/v1/handoff/settle", 7)
    open_state = settling_older_stop_state
    expect(open_state).to include("settling_generation" => 7)

    2.times do
      settling_older_stop_post("/internal/v1/handoff/stop_applying", 6)
      expect(response).to have_http_status(:ok)
      expect(settling_older_stop_state).to eq(open_state)
    end
    expect(Timekeeping::Admission.settling?).to be(true)
  end
end

RSpec.describe "POST /internal/v1/handoff/settle and stop_applying with a malformed generation", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
  # A generation beyond the bigint column must also be refused rather than answered with a 500.
  it "refuses a string, a decimal or an out-of-range generation with invalid_request and leaves the fenced admission row unchanged" do
    Timekeeping::Admission.fence!
    baseline = Timekeeping::Admission.current.attributes.slice("generation", "settling_generation", "settling_stopped_generation")
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    bodies = ['{"generation":"3"}', '{"generation":3.0}', '{"generation":0}', '{"generation":null}',
              "{\"generation\":#{2**64}}", "{}"]

    %w[/internal/v1/handoff/settle /internal/v1/handoff/stop_applying].each do |path|
      bodies.each do |body|
        post path, params: body, headers: headers

        expect([path, body, response.status, response.parsed_body])
          .to eq([path, body, 400, { "reason" => "invalid_request" }])
        expect(Timekeeping::Admission.current.attributes.slice("generation", "settling_generation", "settling_stopped_generation"))
          .to eq(baseline)
      end
    end
  end
end

RSpec.describe "POST /internal/v1/handoff/settle and stop_applying without an admission row", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  # A missing row must never read as a settle step opened or stopped.
  it "answers admission_missing for settle and stop_applying and creates no admission row" do
    Timekeeping::Admission.delete_all
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }

    %w[/internal/v1/handoff/settle /internal/v1/handoff/stop_applying].each do |path|
      post path, params: JSON.generate(generation: 4), headers: headers

      expect([path, response.status, response.parsed_body]).to eq([path, 409, { "reason" => "admission_missing" }])
      expect([path, Timekeeping::Admission.count]).to eq([path, 0])
    end
  end
end

# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping internal handoff drain persistence" do
  include_context "timekeeping entry writes without transactional fixtures"

  around do |example|
    with_handoff_env(public_key: true) { example.run }
  end

  def drain_persistence_post(body)
    params = body.is_a?(String) ? body : JSON.generate(body)
    post "/internal/v1/handoff/drain", params:,
                                       headers: { "Content-Type" => "application/json",
                                                  "Authorization" => "Bearer #{handoff_service_token}" }
    [response.status, response.parsed_body]
  end

  # "`generation` must be a positive integer and `through` a non-negative one. A missing, negative or
  # non-integer value gets a refusal reason from timekeeping/app/services/timekeeping/reasons.rb and changes nothing."
  it "a malformed drain through is refused before the relay runs and leaves the unsent snapshot unsent" do
    at = Time.utc(2026, 3, 2, 9)
    OutboxSnapshot.insert_all!([{
      outbox_position: 17, id: 5, company_id: 1, version: 1, generation: 1, project_id: 10, user_id: 20,
      work_date: Date.new(2026, 3, 2), duration: 30.0, bill_status: "unbilled", review_status: "not_required",
      locked: false, source: "manual", source_metadata: {}, proof_metadata: {}, created_at: at, updated_at: at
    }])
    allow(RelayJob).to receive(:perform_now).and_call_original
    baseline = handoff_stored_rows

    bodies = {
      "missing" => {}, "negative" => { through: -1 }, "string" => { through: "17" },
      "float" => '{"through": 17.5}', "null" => { through: nil }, "boolean" => { through: true },
      "false" => { through: false }, "not an object" => "[17]"
    }
    bodies.each do |label, body|
      answer = drain_persistence_post(body)

      expect([label, answer]).to eq([label, [400, { "reason" => "invalid_request" }]])
      expect([label, handoff_stored_rows]).to eq([label, baseline])
    end
    expect(RelayJob).not_to have_received(:perform_now)
    expect(OutboxSnapshot.where(outbox_position: 17).pick(:sent_at)).to be_nil
  end
end

RSpec.describe "Timekeeping internal handoff drain repeat" do
  include_context "timekeeping entry writes without transactional fixtures"

  around do |example|
    with_handoff_env(public_key: true) { example.run }
  end

  def drain_repeat_post(body)
    post "/internal/v1/handoff/drain", params: JSON.generate(body),
                                       headers: { "Content-Type" => "application/json",
                                                  "Authorization" => "Bearer #{handoff_service_token}" }
    [response.status, response.parsed_body]
  end

  # "A repeated identical request leaves the same state."
  it "a repeated drain over already-sent snapshots answers drained true each time and changes no row" do
    at = Time.utc(2026, 3, 2, 9)
    snapshot = {
      id: 5, company_id: 1, version: 1, generation: 1, project_id: 10, user_id: 20, work_date: Date.new(2026, 3, 2),
      duration: 30.0, bill_status: "unbilled", review_status: "not_required", locked: false, source: "manual",
      source_metadata: {}, proof_metadata: {}, created_at: at, updated_at: at, sent_at: at
    }
    OutboxSnapshot.insert_all!([snapshot.merge(outbox_position: 17), snapshot.merge(outbox_position: 42, version: 2)])
    baseline = handoff_stored_rows

    first = drain_repeat_post({ through: 42 })
    after_first = handoff_stored_rows
    second = drain_repeat_post({ through: 42 })

    # "It answers `drained`, which is true only when no outbox_snapshots row with position at or below P has `sent_at` NULL."
    expect(first).to eq([200, { "drained" => true }])
    expect(second).to eq(first)
    expect(after_first).to eq(baseline)
    expect(handoff_stored_rows).to eq(baseline)
  end
end

RSpec.describe "POST /internal/v1/handoff/drain", type: :request do
  # "drain answers false while the snapshot at P is unsent and true once it is sent. An unsent row above P does not matter."
  it "drain answers drained true when the only unsent snapshot sits above through" do
    insert_outbox_rows(
      outbox_row(outbox_position: 30, id: 930, sent_at: Time.utc(2026, 3, 3, 9, 0, 0)),
      outbox_row(outbox_position: 31, id: 931)
    )
    # The monolith refuses every batch, so the row above P stays unsent.
    WebMock.stub_request(:post, "http://snapshots.test/internal/v1/timekeeping/entry-snapshots")
      .to_return(status: 503, body: "")

    with_handoff_env(public_key: false) do
      with_timekeeping_env(Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => "http://snapshots.test") do
        post "/internal/v1/handoff/drain",
             params: JSON.generate(through: 30),
             headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("drained" => true)
    expect(OutboxSnapshot.where(outbox_position: 31).pick(:sent_at)).to be_nil
  end
end

RSpec.describe "POST /internal/v1/handoff/drain while a scheduled relay holds the lock", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  # "A relay that skipped on its advisory lock leaves `drained` false."
  it "answers drained false when another connection holds the relay lock, even with every row at or below through sent" do
    sent_at = Time.current.change(usec: 0)
    insert_outbox_rows(outbox_row(outbox_position: 10, id: 801, sent_at:))
    insert_outbox_rows(outbox_row(outbox_position: 20, id: 802))
    snapshot_url = "http://snapshots.drain-lock.test"
    WebMock.stub_request(:post, "#{snapshot_url}/internal/v1/timekeeping/entry-snapshots")
           .to_return(status: 200, body: "{}")
    other_connection = PG.connect(Timekeeping::Environment.database_url)
    begin
      other_connection.exec_params("SELECT pg_advisory_lock($1)", [RelayJob::RELAY_LOCK_KEY])

      with_timekeeping_env(Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => snapshot_url) do
        post "/internal/v1/handoff/drain",
             params: JSON.generate(through: 10),
             headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
      end
    ensure
      other_connection.close
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("drained" => false)
    expect(a_request(:post, "#{snapshot_url}/internal/v1/timekeeping/entry-snapshots")).not_to have_been_made
    expect(OutboxSnapshot.where(outbox_position: 20).pick(:sent_at)).to be_nil
  end
end

RSpec.describe "POST /internal/v1/handoff/drain when delivery fails part way", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  # "It answers `drained`, which is true only when no outbox_snapshots row with position at or below P has `sent_at` NULL."
  # The relay ran (it held its lock), so an answer taken from whether the job ran would wrongly say true.
  it "answers drained false when the relay ran but the monolith refused the batch holding the row at through" do
    insert_outbox_rows(outbox_row(outbox_position: 30, id: 811))
    snapshot_url = "http://snapshots.drain-refused.test"
    snapshot_stub = WebMock.stub_request(:post, "#{snapshot_url}/internal/v1/timekeeping/entry-snapshots")
                           .to_return(status: 503, body: "")

    with_timekeeping_env(Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => snapshot_url) do
      post "/internal/v1/handoff/drain",
           params: JSON.generate(through: 30),
           headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    end

    expect(snapshot_stub).to have_been_requested.at_least_once
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("drained" => false)
    expect(OutboxSnapshot.where(outbox_position: 30).pick(:sent_at)).to be_nil
  end
end

RSpec.describe "POST /internal/v1/handoff/drain until the snapshot at through is sent", type: :request do
  include_context "timekeeping entry writes without transactional fixtures"

  around { |example| with_handoff_env(public_key: false) { example.run } }

  def drain_until_sent_post(through)
    post "/internal/v1/handoff/drain",
         params: JSON.generate(through:),
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{handoff_service_token}" }
    [response.status, response.parsed_body]
  end

  # "drain answers false while the snapshot at P is unsent and true once it is sent."
  it "answers drained false while the monolith refuses the snapshot at through and true once a later drain sends it" do
    insert_outbox_rows(outbox_row(outbox_position: 40, id: 831))
    snapshot_url = "http://snapshots.drain-until-sent.test"
    WebMock.stub_request(:post, "#{snapshot_url}/internal/v1/timekeeping/entry-snapshots")
           .to_return({ status: 503, body: "" },
                      { status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(applied: 1, ignored: 0) })

    with_timekeeping_env(Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => snapshot_url) do
      expect(drain_until_sent_post(40)).to eq([200, { "drained" => false }])
      expect(OutboxSnapshot.where(outbox_position: 40).pick(:sent_at)).to be_nil

      expect(drain_until_sent_post(40)).to eq([200, { "drained" => true }])
    end
    expect(OutboxSnapshot.where(outbox_position: 40).pick(:sent_at)).not_to be_nil
  end

  # "`through` a non-negative one": zero and a position beyond any stored one are both accepted.
  it "accepts a through of 0 and a through of 2**64 and answers from the rows at or below it" do
    insert_outbox_rows(outbox_row(outbox_position: 7, id: 832, sent_at: Time.current))

    expect(drain_until_sent_post(0)).to eq([200, { "drained" => true }])
    expect(drain_until_sent_post(2**64)).to eq([200, { "drained" => true }])
  end
end

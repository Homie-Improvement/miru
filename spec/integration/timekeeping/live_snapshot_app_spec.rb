# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingLiveSnapshotApp do
  it "live snapshot app answers 401 to a missing or wrong bearer token and never hands the batch to the consumer" do
    expect_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).not_to receive(:deliver)
    app = described_class.new
    app.service_token = "live-service-right-token"
    body = JSON.generate("snapshots" => [{ "entry" => { "company_id" => 1 } }])

    missing = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                        method: "POST", input: body, "CONTENT_TYPE" => "application/json",
                                        "HTTP_IDEMPOTENCY_KEY" => "key-missing")
    wrong = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                      method: "POST", input: body, "CONTENT_TYPE" => "application/json",
                                      "HTTP_IDEMPOTENCY_KEY" => "key-wrong",
                                      "HTTP_AUTHORIZATION" => "Bearer live-service-wrong-token")

    [missing, wrong].each do |env|
      status, _headers, response_body = app.call(env)
      expect(status).to eq(401)
      text = +""
      response_body.each { |chunk| text << chunk }
      expect(text).not_to include("live-service-right-token")
    end
    expect(app.answer_for(1)).to be_nil
  end
end

RSpec.describe TimekeepingLiveSnapshotApp do
  it "live snapshot app refuses every request before its service token is set, even one sending an empty bearer" do
    expect_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).not_to receive(:deliver)
    app = described_class.new
    body = JSON.generate("snapshots" => [{ "entry" => { "company_id" => 1 } }])

    ["Bearer ", "Bearer", nil].each do |authorization|
      headers = { method: "POST", input: body, "CONTENT_TYPE" => "application/json",
                  "HTTP_IDEMPOTENCY_KEY" => SecureRandom.uuid }
      headers["HTTP_AUTHORIZATION"] = authorization if authorization
      env = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots", **headers)

      status, = app.call(env)
      expect(status).to eq(401)
    end
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  it "live snapshot app hands the batch to the consumer with the relay's Idempotency-Key and exact decimals" do
    received = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).to receive(:deliver) do |_endpoint, batch, idempotency_key:|
      received << [batch, idempotency_key]
      TimekeepingRelay::Response.new(status: 200, body: { "applied" => 1 })
    end
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-token"
    body = '{"snapshots":[{"generation":2,"outbox_position":1,' \
           '"entry":{"id":7,"company_id":42,"duration":1.123456789012345678}}]}'
    env = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                    method: "POST", input: body,
                                    "CONTENT_TYPE" => "application/json",
                                    "HTTP_AUTHORIZATION" => "Bearer live-token",
                                    "HTTP_IDEMPOTENCY_KEY" => "relay-key-1")

    status, = app.call(env)

    expect(status).to eq(200)
    expect(received.size).to eq(1)
    batch, key = received.first
    # A relay retry carries the same key, so the consumer can absorb it instead of storing a second row.
    expect(key).to eq("relay-key-1")
    duration = batch.fetch("snapshots").first.dig("entry", "duration")
    expect(duration).to be_a(BigDecimal)
    expect(duration).to eq(BigDecimal("1.123456789012345678"))
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  it "live snapshot app answers a consumer refusal and keeps it for every company in a mixed batch" do
    refusal = TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" })
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).to receive(:deliver).and_return(refusal)
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-token"
    body = JSON.generate("snapshots" => [
                           { "generation" => 2, "outbox_position" => 1, "entry" => { "id" => 1, "company_id" => 11 } },
                           { "generation" => 2, "outbox_position" => 2, "entry" => { "id" => 2, "company_id" => 22 } }
                         ])
    env = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                    method: "POST", input: body,
                                    "CONTENT_TYPE" => "application/json",
                                    "HTTP_AUTHORIZATION" => "Bearer live-token",
                                    "HTTP_IDEMPOTENCY_KEY" => "relay-key-2")

    status, = app.call(env)

    # The relay must see the refusal so it stops and leaves the rows unsent rather than marking them delivered.
    expect(status).to eq(409)
    expect(app.answer_for(11)&.status).to eq(409)
    expect(app.answer_for(22)&.status).to eq(409)
  end
end

RSpec.describe TimekeepingLiveSnapshotApp do
  it "a refused mixed-company batch is saved under each company in it and under no other company" do
    company_a_id = 9_558_101
    company_b_id = 9_558_102
    outside_company_id = 9_558_103
    refusal = TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" })
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).to receive(:deliver).and_return(refusal)

    app = described_class.new
    app.service_token = "live-snapshot-tenant-token"
    batch = {
      "snapshots" => [
        { "generation" => 2, "outbox_position" => 1, "entry" => { "id" => 1, "company_id" => company_a_id } },
        { "generation" => 2, "outbox_position" => 2, "entry" => { "id" => 2, "company_id" => company_b_id } }
      ]
    }
    env = Rack::MockRequest.env_for(
      TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
      method: "POST",
      input: JSON.generate(batch),
      "CONTENT_TYPE" => "application/json",
      "HTTP_AUTHORIZATION" => "Bearer live-snapshot-tenant-token",
      "HTTP_IDEMPOTENCY_KEY" => "live-snapshot-tenant-key"
    )

    status, = app.call(env)

    expect(status).to eq(409)
    # The live relay picks rows by outbox position only, so a refusal must be findable under every company it carried.
    expect(app.answer_for(company_a_id)&.status).to eq(409)
    expect(app.answer_for(company_b_id)&.status).to eq(409)
    # A company that had no snapshot in the batch is never given another company's answer.
    expect(app.answer_for(outside_company_id)).to be_nil
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  # "start the live instance in TimekeepingRegressionAdapter.launch with a snapshot_app that wraps TimekeepingHandoffOutboxRelay::ConsumerEndpoint."
  it "an authorized snapshot POST reaches ConsumerEndpoint#deliver with its Idempotency-Key and exact decimals and answers the consumer's status" do
    delivered = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint) # rubocop:disable RSpec/AnyInstance
      .to receive(:deliver) do |_endpoint, batch, idempotency_key:|
        delivered << [batch, idempotency_key]
        TimekeepingRelay::Response.new(status: 200, body: { "accepted" => 1 })
      end
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    raw = '{"snapshots":[{"generation":2,"outbox_position":1,"entry":{"company_id":41,"duration":1.123456789012345678}}]}'

    response = Rack::MockRequest.new(app).post(
      TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
      input: raw, "CONTENT_TYPE" => "application/json",
      "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token", "HTTP_IDEMPOTENCY_KEY" => "batch-key-1"
    )

    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to eq("accepted" => 1)
    expect(delivered.size).to eq(1)
    batch, key = delivered.first
    expect(key).to eq("batch-key-1")
    duration = batch.fetch("snapshots").first.fetch("entry").fetch("duration")
    expect(duration).to be_a(BigDecimal)
    expect(duration).to eq(BigDecimal("1.123456789012345678"))
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  it "a snapshot POST with a wrong bearer token answers 401 and never reaches the consumer" do
    expect_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint) # rubocop:disable RSpec/AnyInstance
      .not_to receive(:deliver)
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    raw = '{"snapshots":[{"generation":2,"outbox_position":1,"entry":{"company_id":41}}]}'

    wrong = Rack::MockRequest.new(app).post(TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
                                            input: raw, "HTTP_AUTHORIZATION" => "Bearer other-token",
                                            "HTTP_IDEMPOTENCY_KEY" => "k1")
    missing = Rack::MockRequest.new(app).post(TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
                                              input: raw, "HTTP_IDEMPOTENCY_KEY" => "k2")

    expect(wrong.status).to eq(401)
    expect(missing.status).to eq(401)
    expect(app.answer_for(41)).to be_nil
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  it "a refused batch mixing two companies is answered 409 and kept as the answer for both companies" do
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint) # rubocop:disable RSpec/AnyInstance
      .to receive(:deliver)
      .and_return(TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" }))
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    raw = JSON.generate("snapshots" => [
                          { "generation" => 2, "outbox_position" => 1, "entry" => { "company_id" => 51 } },
                          { "generation" => 2, "outbox_position" => 2, "entry" => { "company_id" => 52 } }
                        ])

    response = Rack::MockRequest.new(app).post(TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
                                               input: raw, "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token",
                                               "HTTP_IDEMPOTENCY_KEY" => "mixed-key")

    expect(response.status).to eq(409)
    expect(JSON.parse(response.body)).to eq("reason" => "stale_generation")
    expect(app.answer_for(51).status).to eq(409)
    expect(app.answer_for(52).status).to eq(409)
    expect(app.answer_for(53)).to be_nil
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  # The live relay picks outbox rows by position only, so one batch can carry two companies.
  # Issue: "Have run_harvest_import wait for that delivery and verify it in the timekeeping state, the same way it runs the relay in rollback."
  it "a refused batch mixing two companies is answered 409 and its refusal is kept under both companies" do
    refusal = TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" })
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).to receive(:deliver).and_return(refusal)
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    batch = { "snapshots" => [
      { "generation" => 2, "outbox_position" => 1, "entry" => { "id" => 101, "company_id" => 7101 } },
      { "generation" => 2, "outbox_position" => 2, "entry" => { "id" => 102, "company_id" => 7102 } }
    ] }
    env = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                    method: "POST", input: JSON.generate(batch),
                                    "CONTENT_TYPE" => "application/json",
                                    "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token",
                                    "HTTP_IDEMPOTENCY_KEY" => "mixed-batch-key")

    status, = app.call(env)

    expect(status).to eq(409)
    expect(app.answer_for(7101)&.status).to eq(409)
    expect(app.answer_for(7102)&.status).to eq(409)
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  it "a batch sent with a wrong bearer token is answered 401 and never reaches the projection consumer" do
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).to receive(:deliver)
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    batch = { "snapshots" => [{ "generation" => 2, "outbox_position" => 1,
                                "entry" => { "id" => 201, "company_id" => 7201 } }] }
    env = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                    method: "POST", input: JSON.generate(batch),
                                    "CONTENT_TYPE" => "application/json",
                                    "HTTP_AUTHORIZATION" => "Bearer some-other-token",
                                    "HTTP_IDEMPOTENCY_KEY" => "wrong-token-key")

    status, = app.call(env)

    expect(status).to eq(401)
    expect_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).not_to receive(:deliver)
    expect(app.answer_for(7201)).to be_nil
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  # A drain is retried until delivered, so the consumer's idempotency must see the relay's own key every time.
  it "a relay retry of the same batch reaches the consumer under the same Idempotency-Key both times" do
    keys = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint)
      .to receive(:deliver) do |_endpoint, _batch, idempotency_key:|
        keys << idempotency_key
        TimekeepingRelay::Response.new(status: 200, body: { "applied" => 1 })
      end
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    batch = { "snapshots" => [{ "generation" => 2, "outbox_position" => 5,
                                "entry" => { "id" => 301, "company_id" => 7301 } }] }

    2.times do
      env = Rack::MockRequest.env_for("/internal/v1/timekeeping/entry-snapshots",
                                      method: "POST", input: JSON.generate(batch),
                                      "CONTENT_TYPE" => "application/json",
                                      "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token",
                                      "HTTP_IDEMPOTENCY_KEY" => "retried-batch-key")
      status, = app.call(env)
      expect(status).to eq(200)
    end

    expect(keys).to eq(%w[retried-batch-key retried-batch-key])
  end
end

RSpec.describe "TimekeepingLiveSnapshotApp" do
  it "live snapshot app hands a body that is not JSON to the consumer as nil, so the consumer refuses it" do
    received = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint)
      .to receive(:deliver) do |_endpoint, batch, idempotency_key:|
        received << [batch, idempotency_key]
        TimekeepingRelay::Response.new(status: 422, body: { "reason" => "invalid_batch" })
      end
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    env = Rack::MockRequest.env_for(TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
                                    method: "POST", input: "not json {",
                                    "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token",
                                    "HTTP_IDEMPOTENCY_KEY" => "not-json-key")

    status, = app.call(env)

    expect(status).to eq(422)
    expect(received).to eq([[nil, "not-json-key"]])
  end

  it "live snapshot app answers 404 to an authorized request on any other path and never calls the consumer" do
    expect_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint).not_to receive(:deliver)
    app = TimekeepingLiveSnapshotApp.new
    app.service_token = "live-snapshot-token"
    env = Rack::MockRequest.env_for("/internal/v1/other", method: "POST", input: "{}",
                                                          "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token")

    status, = app.call(env)

    expect(status).to eq(404)
  end
end

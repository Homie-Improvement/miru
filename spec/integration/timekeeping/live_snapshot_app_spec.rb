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

  # "start the live instance in TimekeepingRegressionAdapter.launch with a snapshot_app that wraps TimekeepingHandoffOutboxRelay::ConsumerEndpoint."
  it "an authorized snapshot POST reaches ConsumerEndpoint#deliver with its Idempotency-Key and exact decimals and answers the consumer's status" do
    delivered = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint)
      .to receive(:deliver) do |_endpoint, batch, idempotency_key:|
        delivered << [batch, idempotency_key]
        TimekeepingRelay::Response.new(status: 200, body: { "accepted" => 1 })
      end
    app = described_class.new
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
    # A relay retry carries the same key, so the consumer can absorb it instead of storing a second row.
    expect(key).to eq("batch-key-1")
    duration = batch.fetch("snapshots").first.fetch("entry").fetch("duration")
    expect(duration).to be_a(BigDecimal)
    expect(duration).to eq(BigDecimal("1.123456789012345678"))
  end

  # The live relay picks outbox rows by position only, so one batch can carry two companies.
  it "a refused batch mixing two companies is answered 409 and kept as the answer for both companies" do
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint)
      .to receive(:deliver)
      .and_return(TimekeepingRelay::Response.new(status: 409, body: { "reason" => "stale_generation" }))
    app = described_class.new
    app.service_token = "live-snapshot-token"
    raw = JSON.generate("snapshots" => [
                          { "generation" => 2, "outbox_position" => 1, "entry" => { "company_id" => 51 } },
                          { "generation" => 2, "outbox_position" => 2, "entry" => { "company_id" => 52 } }
                        ])

    response = Rack::MockRequest.new(app).post(TimekeepingRelay::HttpEndpoint::DELIVER_PATH,
                                               input: raw, "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token",
                                               "HTTP_IDEMPOTENCY_KEY" => "mixed-key")

    # The relay must see the refusal so it stops and leaves the rows unsent rather than marking them delivered.
    expect(response.status).to eq(409)
    expect(JSON.parse(response.body)).to eq("reason" => "stale_generation")
    expect(app.answer_for(51).status).to eq(409)
    expect(app.answer_for(52).status).to eq(409)
    # A company that had no snapshot in the batch is never given another company's answer.
    expect(app.answer_for(53)).to be_nil
  end

  # A drain is retried until delivered, so the consumer's idempotency must see the relay's own key every time.
  it "a relay retry of the same batch reaches the consumer under the same Idempotency-Key both times" do
    keys = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint)
      .to receive(:deliver) do |_endpoint, _batch, idempotency_key:|
        keys << idempotency_key
        TimekeepingRelay::Response.new(status: 200, body: { "applied" => 1 })
      end
    app = described_class.new
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

  it "live snapshot app hands a body that is not JSON to the consumer as nil, so the consumer refuses it" do
    received = []
    allow_any_instance_of(TimekeepingHandoffOutboxRelay::ConsumerEndpoint)
      .to receive(:deliver) do |_endpoint, batch, idempotency_key:|
        received << [batch, idempotency_key]
        TimekeepingRelay::Response.new(status: 422, body: { "reason" => "invalid_batch" })
      end
    app = described_class.new
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
    app = described_class.new
    app.service_token = "live-snapshot-token"
    env = Rack::MockRequest.env_for("/internal/v1/other", method: "POST", input: "{}",
                                                          "HTTP_AUTHORIZATION" => "Bearer live-snapshot-token")

    status, = app.call(env)

    expect(status).to eq(404)
  end
end

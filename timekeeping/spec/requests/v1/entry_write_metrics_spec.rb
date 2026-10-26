# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes: write metrics" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:other_project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:entries_path) { "/v1/companies/#{company}/entries" }
  let(:other_entries_path) { "/v1/companies/#{other_company}/entries" }

  def metric_entry_body
    { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
      "source" => "manual", "source_metadata" => {} }
  end

  def metric_write_headers(token)
    headers = { "Content-Type" => "application/json", "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    headers["Authorization"] = "Bearer #{token}" if token
    headers
  end

  def send_metric_write(method, path, token, body = nil)
    process(method, path, params: body && JSON.generate(body), headers: metric_write_headers(token))
    response
  end

  def expired_owner_token(key: TimekeepingProviderArrange.signing_key)
    now = Time.now.to_i
    JWT.encode({ sub: owner, company_id: company, role: "owner", iat: now - 120, exp: now - 60,
                 jti: SecureRandom.uuid }, key, "RS256")
  end

  # [writes, reference_unavailable] of each company's rows, once every pending
  # event is folded into them.
  def metric_counts
    Timekeeping::WriteMetrics.fold_pending
    WriteMetricWindow.group(:company_id).pluck(:company_id, Arel.sql("SUM(writes)"), Arel.sql("SUM(reference_unavailable)"))
                     .to_h { |company_id, writes, unavailable| [company_id, [writes, unavailable]] }
  end

  describe "requests without a verified signature" do
    it "records nothing for a bad-signature or missing token to an arbitrary path company" do
      forged = JWT.encode({ sub: 1, company_id: 999_999, role: "owner", iat: Time.now.to_i, exp: Time.now.to_i + 60,
                            jti: SecureRandom.uuid }, OpenSSL::PKey::RSA.generate(2048), "RS256")

      [forged, nil].each do |token|
        send_metric_write(:post, "/v1/companies/999999/entries", token, metric_entry_body)
        expect(response.status).to eq(401)
      end
      expect([WriteMetricEvent.count, WriteMetricWindow.count]).to eq([0, 0])
    end

    it "records nothing for an expired token signed with another key" do
      send_metric_write(:post, other_entries_path, expired_owner_token(key: OpenSSL::PKey::RSA.generate(2048)),
                        metric_entry_body)

      expect(response.status).to eq(401)
      expect([WriteMetricEvent.count, WriteMetricWindow.count]).to eq([0, 0])
    end
  end

  it "counts a validly signed expired token's 503 under the token's company, not the path company" do
    send_metric_write(:post, other_entries_path, expired_owner_token, metric_entry_body)

    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])
    expect(metric_counts).to eq(company => [0, 1])
  end

  it "counts two writes and one reference_unavailable refusal for company A and nothing for company B" do
    other_company
    2.times { expect(send_metric_write(:post, entries_path, owner_token, metric_entry_body).status).to eq(201) }
    WebMock.stub_request(:get, /reference\.test/).to_return(status: 500, body: "")
    expect(send_metric_write(:post, entries_path, owner_token, metric_entry_body).status).to eq(503)

    expect(metric_counts).to eq(company => [2, 1])
    row = WriteMetricWindow.find_by!(company_id: company)
    expect(row.window_start).to eq(Time.utc(2026, 3, 3, 12))
    expect(row.latency_ms_buckets.values.sum).to eq(3)
  end

  it "stores each request's measured latency in whole ms, on both sides of the 300 ms edge" do
    # Start and end readings of the monotonic clock, in ms, for two requests:
    # one that takes exactly 300 ms and one that takes 300.4 ms.
    readings = [1000.0, 1300.0, 2000.0, 2300.4]
    allow_any_instance_of(Timekeeping::V1::EntriesController).to receive(:monotonic_ms) { readings.shift }

    2.times { expect(send_metric_write(:post, entries_path, owner_token, metric_entry_body).status).to eq(201) }

    row = Timekeeping::WriteMetrics.folded_windows.find_by!(company_id: company)
    expect([row.latency_ms_sum, row.latency_ms_buckets]).to eq([601, { "300" => 1, "500" => 1 }])
  end

  it "counts a write to another company's path under the token's company" do
    send_metric_write(:post, other_entries_path, owner_token, metric_entry_body)

    expect(response.status).to eq(404)
    expect(metric_counts).to eq(company => [1, 0])
  end

  it "counts a write whose transaction rolled back" do
    allow(Timekeeping::EntryWriter).to receive(:new).and_wrap_original do |original|
      original.call(checkpoint: ->(step) { raise "metric spec rollback" if step == :audit_written })
    end

    expect { send_metric_write(:post, entries_path, owner_token, metric_entry_body) }
      .to raise_error(RuntimeError, "metric spec rollback")
    expect(Entry.count).to eq(0)
    expect(metric_counts).to eq(company => [1, 0])
  end

  it "counts a body that is not JSON" do
    post entries_path, params: "{not json", headers: metric_write_headers(owner_token)

    expect([response.status, response.parsed_body]).to eq([400, { "reason" => "invalid_request" }])
    expect(metric_counts).to eq(company => [1, 0])
  end

  it "leaves the write's answer unchanged when the metric cannot be recorded" do
    allow_any_instance_of(Timekeeping::WriteMetrics).to receive(:record).and_raise(ActiveRecord::StatementInvalid)

    send_metric_write(:post, entries_path, owner_token, metric_entry_body)

    expect(response.status).to eq(201)
    expect(response.parsed_body).to include("company_id" => company, "note" => "Review")
    expect([WriteMetricEvent.count, WriteMetricWindow.count]).to eq([0, 0])
  end

  it "records one write for each write route" do
    entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
    other_entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
    routes = [
      [:post, entries_path, metric_entry_body],
      [:patch, "#{entries_path}/#{entry_id}", { "note" => "Edited" }],
      [:delete, "#{entries_path}/#{other_entry_id}", nil],
      [:post, "#{entries_path}/bulk-move", { "entry_ids" => [entry_id], "project_id" => other_project }],
      [:post, "#{entries_path}/bulk-delete", { "entry_ids" => [entry_id] }]
    ]

    routes.each_with_index do |(method, path, body), index|
      send_metric_write(method, path, owner_token, body)

      expect([method, path, metric_counts]).to eq([method, path, { company => [index + 1, 0] }])
    end
  end

  # Generated by Descant: acceptance tests below.
  describe "pending metric events" do
    # Each company's total writes as the metrics endpoint answers them.
    def pending_metric_read_writes
      get "/internal/v1/metrics", headers: { "Authorization" => "Bearer #{provider_service_token}" }
      expect(response.status).to eq(200)
      response.parsed_body.fetch("companies").to_h do |entry|
        [entry.fetch("company_id"), entry.fetch("windows").sum { |window| window.fetch("writes") }]
      end
    end

    it "stores the pending event of a write to another company's path under the token's company until a metrics read folds it" do
      send_metric_write(:post, other_entries_path, owner_token, metric_entry_body)

      expect(response.status).to eq(404)
      expect(WriteMetricEvent.pluck(:company_id, :writes, :reference_unavailable)).to eq([[company, 1, 0]])
      expect(pending_metric_read_writes).to eq(company => 1)
      expect(WriteMetricEvent.count).to eq(0)
    end

    # The issue asks: "Does a locked metric row delay an entry response after the entry transaction commits?"
    # On the old code the metric upsert waits until the holder gives up after 10 seconds, so the
    # response arrives only after the row is released.
    it "answers a committed create while its metric row is held and counts it once on the first metrics read after release" do
      expect(send_metric_write(:post, entries_path, owner_token, metric_entry_body).status).to eq(201)
      expect(pending_metric_read_writes).to eq(company => 1)

      holder, release, = hold_metric_window_row(company)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      send_metric_write(:post, entries_path, owner_token, metric_entry_body)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      still_held = holder.alive?
      status, body = response.status, response.parsed_body
      writes_while_held = pending_metric_read_writes
      release << true
      holder.join(10)

      expect(still_held).to be(true), "the entry response waited for the metric row lock"
      expect(elapsed).to be < 5
      expect(status).to eq(201)
      expect(body).to include("company_id" => company, "note" => "Review")
      expect(Entry.count).to eq(2)
      expect(writes_while_held).to eq(company => 1)

      # "preserves counts rather than discarding timed-out events", with no further entry write.
      expect(pending_metric_read_writes).to eq(company => 2)
      expect(pending_metric_read_writes).to eq(company => 2)
      expect(WriteMetricEvent.count).to eq(0)
    end
  end
end

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
end

# Generated by Descant: acceptance tests below.
RSpec.describe "Entry write routes: pending metric events from unverified callers" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }

  def unverified_pending_event_count
    ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM write_metric_events").to_i
  end

  # A request without a verified signature must add nothing, not even a
  # pending row the metrics read would later fold into some company's counts.
  it "leaves no pending metric event for a forged or missing token aimed at an arbitrary path company" do
    forged = JWT.encode({ sub: 1, company_id: 999_999, role: "owner", iat: Time.now.to_i, exp: Time.now.to_i + 60,
                          jti: SecureRandom.uuid }, OpenSSL::PKey::RSA.generate(2048), "RS256")
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }

    [forged, nil].each do |token|
      headers = { "Content-Type" => "application/json", "Idempotency-Key" => SecureRandom.uuid,
                  "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
      headers["Authorization"] = "Bearer #{token}" if token
      post "/v1/companies/999999/entries", params: JSON.generate(body), headers: headers
      expect(response.status).to eq(401)
    end

    expect(unverified_pending_event_count).to eq(0)
    expect(Timekeeping::WriteMetrics.fold_pending).to eq(0)
    expect(WriteMetricWindow.count).to eq(0)
  end
end

RSpec.describe "Entry write routes: pending metric event attribution" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }

  # The pending row is keyed on identity.signed_company_id, never on the
  # company named in the path, so no caller can add counts under a company
  # it names only in the URL.
  it "stores the pending event of a write to another company's path under the signed token's company" do
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Idempotency-Key" => SecureRandom.uuid,
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Authorization" => "Bearer #{owner_token}" }

    post "/v1/companies/#{other_company}/entries", params: JSON.generate(body), headers: headers

    expect(response.status).to eq(404)
    pending_companies = ApplicationRecord.connection.select_values("SELECT company_id FROM write_metric_events").map(&:to_i)
    expect(pending_companies).to eq([company])

    Timekeeping::WriteMetrics.fold_pending
    expect(WriteMetricWindow.pluck(:company_id, :writes)).to eq([[company, 1]])
  end
end

RSpec.describe "Entry write routes: write metrics under a held metric row" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  after { ApplicationRecord.connection.execute("TRUNCATE write_metric_events") }

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner_token) { timekeeping_arrange.token_for(timekeeping_arrange.user(company:, role: "owner")) }

  def held_row_entry_post
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{owner_token}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers
    [response.status, response.parsed_body]
  end

  def held_row_company_writes
    get "/internal/v1/metrics", headers: { "Authorization" => "Bearer #{provider_service_token}" }
    expect(response.status).to eq(200)
    response.parsed_body.fetch("companies").select { |entry| entry["company_id"] == company }
            .flat_map { |entry| entry["windows"] }.sum { |window| window["writes"] }
  end

  # The issue asks: "Does a locked metric row delay an entry response after the entry transaction commits?"
  it "answers a committed create while its metric row is held and shows its count on the next metrics read with no further write" do
    expect(held_row_entry_post.first).to eq(201)
    expect(held_row_company_writes).to eq(1)

    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array(
            ["SELECT 1 FROM write_metric_windows WHERE company_id = ? FOR UPDATE", company]
          ))
          locked << true
          release.pop
        end
      end
    end

    begin
      expect(locked.pop(timeout: 10)).to be(true)
      writer = Thread.new { ApplicationRecord.connection_pool.with_connection { held_row_entry_post } }
      answered = writer.join(5)
      expect(answered).not_to be_nil, "the committed create waited on the held metric row"
      status, body = answered.value
      expect(status).to eq(201)
      expect(body).to include("company_id" => company, "note" => "Review")
    ensure
      release << true
      holder.join(10)
      writer&.join(10)
    end

    expect(Entry.count).to eq(2)
    # The issue asks for persistence that "preserves counts rather than discarding timed-out events".
    expect(held_row_company_writes).to eq(2)
  end
end

require "rails_helper"

RSpec.describe "Entry write routes: pending metric attribution" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "stores the pending metric event of a write to another company's path under the token's company" do
    company = timekeeping_arrange.company
    other_company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    token = timekeeping_arrange.token_for(owner)
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }

    post "/v1/companies/#{other_company}/entries", params: JSON.generate(body), headers: headers

    expect(response.status).to eq(404)
    expect(WriteMetricEvent.pluck(:company_id, :writes, :reference_unavailable)).to eq([[company, 1, 0]])
  end
end

require "rails_helper"

RSpec.describe "Entry write routes: pending metric events without a verified signature" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "stores no pending metric event for an entry write without a verified signature" do
    now = Time.now.to_i
    forged = JWT.encode({ sub: 1, company_id: 999_999, role: "owner", iat: now, exp: now + 60, jti: SecureRandom.uuid },
                        OpenSSL::PKey::RSA.generate(2048), "RS256")
    body = { "project_id" => 1, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }

    [forged, nil].each do |token|
      headers = { "Content-Type" => "application/json", "Idempotency-Key" => SecureRandom.uuid,
                  "Ownership-Generation" => timekeeping_arrange.current_generation.to_s }
      headers["Authorization"] = "Bearer #{token}" if token
      post "/v1/companies/999999/entries", params: JSON.generate(body), headers: headers
      expect(response.status).to eq(401)
    end

    # A request without a verified signature has no signed company, so it must
    # leave nothing behind: neither a pending event nor a counted window.
    expect([WriteMetricEvent.count, WriteMetricWindow.count]).to eq([0, 0])
  end
end

require "rails_helper"

RSpec.describe "Entry write routes: metrics read keyed on the signed company" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "answers a write to another company's path under the token's company on the metrics read" do
    company = timekeeping_arrange.company
    other_company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Idempotency-Key" => SecureRandom.uuid,
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}" }

    post "/v1/companies/#{other_company}/entries", params: JSON.generate(body), headers: headers
    expect(response.status).to eq(404)

    get "/internal/v1/metrics", headers: { "Authorization" => "Bearer #{provider_service_token}" }

    expect(response.status).to eq(200)
    writes_by_company = response.parsed_body.fetch("companies").map do |entry|
      [entry.fetch("company_id"), entry.fetch("windows").sum { |window| window.fetch("writes") }]
    end
    # The count lands under the token's signed company, never the company named in the path.
    expect(writes_by_company).to eq([[company, 1]])
    # The read folds the pending event, so nothing is left waiting.
    expect(WriteMetricEvent.count).to eq(0)
  end
end

RSpec.describe "Entry write routes: write metrics under a held metric row" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }
  let(:entries_path) { "/v1/companies/#{company}/entries" }

  def held_row_entry_body
    { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
      "source" => "manual", "source_metadata" => {} }
  end

  def held_row_write_headers
    { "Content-Type" => "application/json", "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
      "Idempotency-Key" => SecureRandom.uuid, "Authorization" => "Bearer #{owner_token}" }
  end

  it "answers a committed create while the company's metric row is held, and counts it once the lock clears with no further write" do
    post entries_path, params: JSON.generate(held_row_entry_body), headers: held_row_write_headers
    expect(response.status).to eq(201)
    Timekeeping::WriteMetrics.fold_pending
    expect(WriteMetricWindow.find_by!(company_id: company).writes).to eq(1)

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.select_all(ApplicationRecord.sanitize_sql_array(
            ["SELECT id FROM write_metric_windows WHERE company_id = ? FOR UPDATE", company]
          ))
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    # The issue asks: "Does a locked metric row delay an entry response after the entry transaction commits?"
    body = held_row_entry_body
    headers = held_row_write_headers
    writer = Thread.new do
      post entries_path, params: JSON.generate(body), headers: headers
      [response.status, response.parsed_body]
    end
    answered_while_held = writer.join(5)
    release << true
    holder.join(10)
    status, parsed = writer.join(10)&.value

    expect(answered_while_held).not_to be_nil, "the entry response waited for the metric row lock"
    expect(status).to eq(201)
    expect(parsed).to include("company_id" => company, "note" => "Review")
    expect(Entry.count).to eq(2)

    # "preserves counts rather than discarding timed-out events"
    expect(Timekeeping::WriteMetrics.folded_windows.where(company_id: company).sum(:writes)).to eq(2)
    expect(WriteMetricEvent.count).to eq(0)
  end
end

RSpec.describe "Entry write routes: pending metric events without a verified signature" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "leaves no pending metric event for a request without a verified signature" do
    forged = JWT.encode({ sub: 1, company_id: 999_999, role: "owner", iat: Time.now.to_i, exp: Time.now.to_i + 60,
                          jti: SecureRandom.uuid }, OpenSSL::PKey::RSA.generate(2048), "RS256")
    headers = { "Content-Type" => "application/json", "Idempotency-Key" => SecureRandom.uuid,
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Authorization" => "Bearer #{forged}" }

    post "/v1/companies/999999/entries", params: JSON.generate({ "note" => "x" }), headers: headers

    expect(response.status).to eq(401)
    expect([WriteMetricEvent.count, WriteMetricWindow.count]).to eq([0, 0])
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Entry write routes: latency of a folded write metric" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  after { ApplicationRecord.connection.execute("TRUNCATE write_metric_events") }

  # "The recorded latency also excludes this wait." The plan keeps latency_ms
  # as measured around the action, before the metric append, so the stored
  # latency is exactly the two monotonic readings' difference.
  it "records a create's measured 300 ms latency once its pending event is folded" do
    company = timekeeping_arrange.company
    project = timekeeping_arrange.project(company:)
    owner = timekeeping_arrange.user(company:, role: "owner")
    readings = [1000.0, 1300.0]
    allow_any_instance_of(Timekeeping::V1::EntriesController).to receive(:monotonic_ms) { readings.shift }
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Review",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{timekeeping_arrange.token_for(owner)}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s, "Idempotency-Key" => SecureRandom.uuid }

    post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers
    expect(response.status).to eq(201)
    expect(WriteMetricEvent.where(company_id: company).count).to eq(1)

    Timekeeping::WriteMetrics.fold_pending

    row = WriteMetricWindow.find_by!(company_id: company)
    expect([row.writes, row.latency_ms_sum, row.latency_ms_buckets]).to eq([1, 300, { "300" => 1 }])
  end
end

RSpec.describe "Entry write routes: write metrics under a held metric row" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }

  def held_row_entry_post
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 45.0, "note" => "Held",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{owner_token}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers
    response
  end

  # Does a locked metric row delay an entry response after the entry transaction commits?
  # On today's code the metric upsert waits on the held row until the holder gives up after
  # 10 seconds, so the response time below exposes the wait.
  it "answers a committed create with 201 while another session holds the company's metric window row" do
    expect(held_row_entry_post.status).to eq(201)
    Timekeeping::WriteMetrics.fold_pending
    row_id = WriteMetricWindow.find_by!(company_id: company).id

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT id FROM write_metric_windows WHERE id = #{row_id} FOR UPDATE")
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = held_row_entry_post.status
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    still_held = holder.alive?
    release << true
    holder.join(10)

    expect(status).to eq(201)
    expect(response.parsed_body).to include("company_id" => company, "note" => "Held")
    expect(Entry.count).to eq(2)
    expect(still_held).to be(true), "the response only arrived after the metric row was released"
    expect(elapsed).to be < 5
  end
end

RSpec.describe "Entry write routes: metrics read after a held metric row clears" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  let(:company) { timekeeping_arrange.company }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:owner) { timekeeping_arrange.user(company:, role: "owner") }
  let(:owner_token) { timekeeping_arrange.token_for(owner) }

  def release_case_entry_post
    body = { "project_id" => project, "work_date" => "2026-03-02", "duration" => 30.0, "note" => "Release",
             "source" => "manual", "source_metadata" => {} }
    headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{owner_token}",
                "Ownership-Generation" => timekeeping_arrange.current_generation.to_s,
                "Idempotency-Key" => SecureRandom.uuid }
    post "/v1/companies/#{company}/entries", params: JSON.generate(body), headers: headers
    response.status
  end

  def release_case_company_writes
    get "/internal/v1/metrics", headers: { "Authorization" => "Bearer #{provider_service_token}" }
    expect(response.status).to eq(200)
    entry = response.parsed_body.fetch("companies").find { |item| item["company_id"] == company }
    entry.fetch("windows").sum { |window| window["writes"] }
  end

  # This follows the settled plan, so treat response delivery independently from metric
  # persistence as follow-up work that preserves counts rather than discarding timed-out events.
  it "counts a write whose metric met a held row once on the first metrics read after release, with no further entry write" do
    expect(release_case_entry_post).to eq(201)
    expect(release_case_company_writes).to eq(1)
    row_id = WriteMetricWindow.find_by!(company_id: company).id

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT id FROM write_metric_windows WHERE id = #{row_id} FOR UPDATE")
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    expect(release_case_entry_post).to eq(201)
    writes_while_held = release_case_company_writes
    release << true
    holder.join(10)

    expect(writes_while_held).to eq(1)
    expect(release_case_company_writes).to eq(2)
    expect(release_case_company_writes).to eq(2)
    expect(WriteMetricEvent.count).to eq(0)
  end
end

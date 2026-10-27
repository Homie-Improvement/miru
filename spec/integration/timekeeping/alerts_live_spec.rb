# frozen_string_literal: true

require "rails_helper"

# Drives the timekeeping:alerts task against a real Timekeeping server: real
# entry writes over HTTP, the service's own write metrics, and the task's real
# metrics read with the service token. It needs the service's bundle and its
# test database (TIMEKEEPING_DATABASE_URL), so it runs only when
# TIMEKEEPING_LIVE=1; then a server that cannot boot fails the run.
RSpec.describe "timekeeping:alerts against a live Timekeeping server", :without_transaction do
  # Puts every write in the 500 ms bucket, past the 300 ms alert.
  let(:live_write_delay_ms) { 400 }
  # A window must have this long left before a spec writes into it, so all of
  # one spec's writes land in the same window.
  let(:live_window_margin_seconds) { 60 }

  before(:all) do
    skip "Set TIMEKEEPING_LIVE=1 to boot a real Timekeeping server" unless ENV["TIMEKEEPING_LIVE"] == "1"

    WebMock.disable_net_connect!(allow_localhost: true)
    @reference = TimekeepingLiveInstance::ReferenceStub.new
    @timekeeping = TimekeepingLiveInstance.start(reference_stub: @reference)
    @reference.service_token = @timekeeping.service_token
  end

  after(:all) { @timekeeping&.stop }

  before do
    WebMock.disable_net_connect!(allow_localhost: true)
    @reference.down = false
    @timekeeping.clear_metrics!
  end

  def arrange_company
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:owner, company)
    { company:, user:, project: create(:project, client: create(:client, company:)) }
  end

  # Writes count entries for the arranged company and answers their statuses.
  def write_entries(arranged, count)
    company, user, project = arranged.values_at(:company, :user, :project)
    Array.new(count) do
      token = Timekeeping::UserToken.mint(user:, company:, project_ids: [project.id],
                                          private_key: @timekeeping.private_key)
      body = { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 45.0,
               "note" => "Live alert check", "source" => "manual", "source_metadata" => {} }
      @timekeeping.write_entry(company_id: company.id, token:, body:).code.to_i
    end
  end

  def metrics_body
    Timekeeping::MetricsClient.new(base_url: @timekeeping.base_url, service_token: @timekeeping.service_token).fetch
  end

  # Waits for the next window when the current one is about to close.
  def wait_for_room_in_window
    length = metrics_body.fetch("window_seconds")
    remaining = length - (Time.now.to_i % length)
    sleep(remaining + 1) if remaining < live_window_margin_seconds
  end

  # The end of the one window the company's writes landed in.
  def window_end_for(company)
    body = metrics_body
    windows = body.fetch("companies").find { |listed| listed.fetch("company_id") == company.id }.fetch("windows")
    expect(windows.size).to eq(1)
    Time.iso8601(windows.first.fetch("window_start")) + body.fetch("window_seconds")
  end

  # The shared runner turns an abort into an exit status, so a failed live run
  # is checked here; otherwise the example would read the output of a failed run.
  def run_alerts_task(now: nil)
    run = run_timekeeping_alerts_task(base_url: @timekeeping.base_url, token: @timekeeping.service_token, now:)
    expect(run.exit_status).to be_nil, "timekeeping:alerts exited #{run.exit_status}: #{run.stderr}"
    run.stdout
  end

  def alert_lines(output, name, company)
    output.lines.grep(/name=#{name} company_id=#{company.id} /)
  end

  it "raises reference_unavailable for the company whose writes failed, once its window has ended" do
    failing = arrange_company
    healthy = arrange_company
    wait_for_room_in_window

    statuses = write_entries(failing, 17)
    @reference.down = true
    statuses += write_entries(failing, 3)
    @reference.down = false
    healthy_statuses = write_entries(healthy, 20)

    expect(statuses.tally).to eq(201 => 17, 503 => 3)
    expect(healthy_statuses.tally).to eq(201 => 20)

    before_window_end = run_alerts_task
    expect(before_window_end.lines.grep(/name=reference_unavailable_rate /)).to be_empty

    after_window_end = run_alerts_task(now: window_end_for(failing[:company]) + 1)
    expect(alert_lines(after_window_end, "reference_unavailable_rate", failing[:company]).size).to eq(1)
    expect(alert_lines(after_window_end, "reference_unavailable_rate", healthy[:company])).to be_empty
  end

  it "raises the p95 latency alert for writes slowed with the write-delay hook" do
    slowed = arrange_company
    wait_for_room_in_window

    begin
      expect(@timekeeping.service_post("/internal/v1/test-hooks/writes/delay",
                                       "milliseconds" => live_write_delay_ms).code).to eq("204")
      expect(write_entries(slowed, 10).tally).to eq(201 => 10)
    ensure
      @timekeeping.service_post("/internal/v1/test-hooks/writes/clear")
    end

    output = run_alerts_task(now: window_end_for(slowed[:company]) + 1)
    expect(alert_lines(output, "entry_write_p95_latency", slowed[:company]).size).to eq(1)
  end

  # Forty writes, so one write slowed by the server warming up stays under
  # the 5% of requests that would lift the p95 past 300 ms.
  it "raises no latency alert for the same writes without the delay" do
    unslowed = arrange_company
    wait_for_room_in_window
    @timekeeping.service_post("/internal/v1/test-hooks/writes/clear")

    expect(write_entries(unslowed, 40).tally).to eq(201 => 40)

    output = run_alerts_task(now: window_end_for(unslowed[:company]) + 1)
    expect(alert_lines(output, "entry_write_p95_latency", unslowed[:company])).to be_empty
  end
end

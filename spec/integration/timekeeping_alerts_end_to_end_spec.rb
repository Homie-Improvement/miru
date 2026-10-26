# frozen_string_literal: true

require "rails_helper"
require "rake"
require "socket"
require "webrick"

# Runs the timekeeping:alerts task against a real Timekeeping server, started
# from timekeeping/ in its own bundle, so the alerts come from real entry
# writes and a real read of GET /internal/v1/metrics. It needs both test
# databases and TIMEKEEPING_DATABASE_URL, so it runs only when
# TIMEKEEPING_E2E=1, which the timekeeping-alerts-e2e CI job sets.
RSpec.describe "timekeeping:alerts against a running Timekeeping service", if: ENV["TIMEKEEPING_E2E"] == "1" do
  let(:e2e_service_token) { SecureRandom.hex(32) }
  let(:e2e_key_pair) { OpenSSL::PKey::RSA.generate(2048) }
  let(:e2e_timekeeping_root) { Rails.root.join("timekeeping").to_s }

  # rails_helper blocks real connections outside system specs; these examples
  # also talk to the two local servers they start. VCR stays on, because it
  # already ignores localhost and still serves the factories' own requests.
  # rails_helper's around hook blocks connections again once the example ends.
  before do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  # The monolith's suite truncates its tables, so company ids start again on
  # every run while the Timekeeping database keeps its windows. Emptying the
  # windows keeps an earlier run's counts from landing on this run's companies.
  before do
    connection = PG.connect(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    connection.exec("TRUNCATE write_metric_windows")
  ensure
    connection&.close
  end

  def create_e2e_writer
    company = create(:company, timesheet_edit_days: 30)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, client: create(:client, company:), billable: true)
    create(:project_member, project:, user:)
    { company:, user:, project: }
  end

  # The reference endpoint Timekeeping reads before each write, served from
  # facts read here up front, because the examples' rows sit in a transaction
  # the server thread cannot see. Setting available to false answers 500,
  # which Timekeeping turns into 503 reference_unavailable.
  def start_e2e_reference_stub(writers)
    facts = writers.to_h do |writer|
      [writer[:company].id, Timekeeping::ReferenceFacts.call(company: writer[:company], project_ids: [writer[:project].id])]
    end
    available = Concurrent::AtomicBoolean.new(true)
    server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/internal/v1/companies") do |request, response|
      company_id = request.path[%r{/companies/(\d+)/reference\z}, 1].to_i
      if available.false? || request["Authorization"] != "Bearer #{e2e_service_token}" || !facts.key?(company_id)
        response.status = 500
      else
        response.status = 200
        response["Content-Type"] = "application/json"
        response.body = JSON.generate(facts.fetch(company_id))
      end
    end
    thread = Thread.new { server.start }
    { server:, thread:, available:, url: "http://127.0.0.1:#{server.config[:Port]}" }
  end

  def stop_e2e_reference_stub(stub)
    return unless stub

    stub[:server].shutdown
    stub[:thread].join(5)
  end

  def free_e2e_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Starts Timekeeping in the test environment on a free port and waits, for
  # at most boot_timeout seconds, until it accepts connections. A server that
  # exits or never listens fails the example with the tail of its log.
  def start_e2e_timekeeping(reference_url:, write_delay_ms: nil, boot_timeout: 90)
    port = free_e2e_port
    dir = Dir.mktmpdir("timekeeping-e2e")
    log_path = File.join(dir, "server.log")
    env = {
      "RAILS_ENV" => "test",
      "TIMEKEEPING_DATABASE_URL" => ENV.fetch("TIMEKEEPING_DATABASE_URL"),
      "TIMEKEEPING_TOKEN_PUBLIC_KEY" => e2e_key_pair.public_key.to_pem,
      "TIMEKEEPING_SERVICE_TOKEN" => e2e_service_token,
      "TIMEKEEPING_SERVICE_CREDENTIALS" => nil,
      "MONOLITH_REFERENCE_URL" => reference_url,
      "TIMEKEEPING_TEST_WRITE_DELAY_MS" => write_delay_ms&.to_s
    }
    pid = Bundler.with_unbundled_env do
      Process.spawn(env, "bundle", "exec", "rails", "server", "-b", "127.0.0.1", "-p", port.to_s,
                    "-P", File.join(dir, "server.pid"),
                    chdir: e2e_timekeeping_root, out: log_path, err: log_path, pgroup: true)
    end
    process = { pid:, url: "http://127.0.0.1:#{port}", dir: }
    wait_for_e2e_timekeeping(process, port, log_path, boot_timeout)
    process
  rescue StandardError
    stop_e2e_timekeeping(process || (pid && { pid:, dir: }))
    raise
  end

  def wait_for_e2e_timekeeping(process, port, log_path, boot_timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + boot_timeout
    loop do
      if Process.waitpid(process[:pid], Process::WNOHANG)
        process[:pid] = nil
        raise "Timekeeping exited during boot:\n#{File.read(log_path).lines.last(40).join}"
      end
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "Timekeeping did not listen within #{boot_timeout}s:\n#{File.read(log_path).lines.last(40).join}"
        end

        sleep 0.2
      end
    end
  end

  # Stops the whole process group, and kills it if it has not exited within
  # ten seconds, so a stuck server never outlives the example.
  def stop_e2e_timekeeping(process)
    return unless process

    pid = process[:pid]
    if pid
      signal_e2e_group("TERM", pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until Process.waitpid(pid, Process::WNOHANG)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          signal_e2e_group("KILL", pid)
          Process.waitpid(pid)
          break
        end
        sleep 0.1
      end
    end
    FileUtils.remove_entry(process[:dir]) if process[:dir]
  rescue Errno::ECHILD
    nil
  end

  def signal_e2e_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def mint_e2e_token(writer)
    Timekeeping::UserToken.mint(user: writer[:user], company: writer[:company], project_ids: [writer[:project].id],
                                private_key: e2e_key_pair)
  end

  def post_e2e_entry(timekeeping, writer, token)
    uri = URI("#{timekeeping[:url]}/v1/companies/#{writer[:company].id}/entries")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{token}"
    request["Ownership-Generation"] = TimekeepingOwnership.current.generation.to_s
    request["Idempotency-Key"] = SecureRandom.uuid
    request.body = JSON.generate(project_id: writer[:project].id, work_date: Time.now.utc.to_date.iso8601,
                                 duration: 30.0, note: "Alert check", source: "manual", source_metadata: {})
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) { |http| http.request(request) }.code.to_i
  end

  # A read is not a write, so it records no metric; it loads the request path
  # before the measured writes so boot work does not count as write latency.
  def warm_up_e2e_timekeeping(timekeeping, writer, token)
    uri = URI("#{timekeeping[:url]}/v1/companies/#{writer[:company].id}/entries")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
  end

  # The rate alert reads a completed five-minute window. Writing within the
  # last 45 seconds of a window could split the writes across two windows, so
  # this waits for the next one to begin first.
  def wait_away_from_e2e_window_edge
    seconds_left = Timekeeping::Alerts::WINDOW_SECONDS - (Time.now.to_i % Timekeeping::Alerts::WINDOW_SECONDS)
    sleep(seconds_left + 1) if seconds_left < 45
  end

  # Runs the real task in this process with the given token, and returns what
  # it printed and whether it exited with an error.
  def run_e2e_alerts_task(timekeeping, token: e2e_service_token)
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["timekeeping:alerts"].reenable
    saved = ENV.to_h.slice("TIMEKEEPING_BASE_URL", "TIMEKEEPING_SERVICE_TOKEN")
    ENV["TIMEKEEPING_BASE_URL"] = timekeeping[:url]
    ENV["TIMEKEEPING_SERVICE_TOKEN"] = token
    original_stdout, original_stderr = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    failed = false
    begin
      Rake::Task["timekeeping:alerts"].invoke
    rescue SystemExit => e
      failed = !e.success?
    end
    { output: $stdout.string + $stderr.string, failed: }
  ensure
    $stdout, $stderr = original_stdout, original_stderr if original_stdout
    %w[TIMEKEEPING_BASE_URL TIMEKEEPING_SERVICE_TOKEN].each { |key| ENV[key] = saved[key] } if saved
  end

  it "raises reference_unavailable for the company whose writes lost the reference endpoint" do
    writer = create_e2e_writer
    stub = start_e2e_reference_stub([writer])
    timekeeping = start_e2e_timekeeping(reference_url: stub[:url])
    token = mint_e2e_token(writer)
    warm_up_e2e_timekeeping(timekeeping, writer, token)
    wait_away_from_e2e_window_edge

    statuses = Array.new(20) do |index|
      stub[:available].value = !(index % 10).between?(4, 6)
      post_e2e_entry(timekeeping, writer, token)
    end
    stub[:available].make_true

    expect(statuses.tally).to eq(201 => 14, 503 => 6)

    result = travel_to(Time.current + Timekeeping::Alerts::WINDOW_SECONDS.seconds) { run_e2e_alerts_task(timekeeping) }

    expect(result[:failed]).to be(false)
    expect(result[:output]).to include("alert=reference_unavailable company_id=#{writer[:company].id} ")
    expect(result[:output]).not_to include("alert=entry_write_p95_latency")
  ensure
    stop_e2e_timekeeping(timekeeping)
    stop_e2e_reference_stub(stub)
  end

  it "raises the p95 latency alert for writes slowed by the test hook" do
    writer = create_e2e_writer
    stub = start_e2e_reference_stub([writer])
    timekeeping = start_e2e_timekeeping(reference_url: stub[:url], write_delay_ms: 350)
    token = mint_e2e_token(writer)

    statuses = Array.new(5) { post_e2e_entry(timekeeping, writer, token) }

    expect(statuses).to all(eq(201))

    result = run_e2e_alerts_task(timekeeping)

    expect(result[:failed]).to be(false)
    expect(result[:output]).to include("alert=entry_write_p95_latency company_id=#{writer[:company].id} ")
  ensure
    stop_e2e_timekeeping(timekeeping)
    stop_e2e_reference_stub(stub)
  end

  it "exits with an error when the metrics endpoint refuses the task's token" do
    writer = create_e2e_writer
    stub = start_e2e_reference_stub([writer])
    timekeeping = start_e2e_timekeeping(reference_url: stub[:url])
    wrong_token = SecureRandom.hex(32)

    result = run_e2e_alerts_task(timekeeping, token: wrong_token)

    expect(result[:failed]).to be(true)
    expect(result[:output]).not_to match(/no alerts/i)
    expect(result[:output]).not_to include(wrong_token)
    expect(result[:output]).not_to include(e2e_service_token)
  ensure
    stop_e2e_timekeeping(timekeeping)
    stop_e2e_reference_stub(stub)
  end
end

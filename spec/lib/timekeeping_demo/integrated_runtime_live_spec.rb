# frozen_string_literal: true

require "rails_helper"
require "json"
require "net/http"
require "securerandom"

RSpec.describe IntegratedRuntime, "against the live demo runtime" do
  it "the started Timekeeping app answers 200 to a metrics request with the harness service token and every group is gone after the run" do
    # "Live tests skip unless `TIMEKEEPING_LIVE=1`."
    skip "Set TIMEKEEPING_LIVE=1 to start the demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    WebMock.disable_net_connect!(allow_localhost: true)
    groups = nil
    described_class.run(root: Rails.root.to_s, env: ENV.to_h) do |runtime|
      groups = runtime.process_groups
      uri = URI.join(runtime.timekeeping_url, "/internal/v1/metrics")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{runtime.credentials.service_token}"
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }

      # "`GET /internal/v1/metrics` from the test process, with the harness token as Bearer, gets 200."
      expect(response.code).to eq("200")
    end

    # "After `stop!`, no recorded group is alive: `Process.kill(0, -pgid)` raises `Errno::ESRCH`."
    recorded = described_class.parse_groups(File.read(Rails.root.join("tmp", "timekeeping-demo", "process_groups")))
    expect(recorded).not_to be_empty
    (Array(groups) | recorded).each do |pgid|
      expect { Process.kill(0, -pgid) }.to raise_error(Errno::ESRCH)
    end
  end
end

RSpec.describe "IntegratedRuntime against the real bin/timekeeping-demo up" do
  # "`IntegratedRuntime.start(root:, env:)` returns a runtime with `monolith_url`, `timekeeping_url`, `credentials`, `process_groups` and an idempotent `stop!`."
  it "start returns a runtime with both urls, the credentials and its process groups, and stop! can be called twice" do
    # "Live tests skip unless `TIMEKEEPING_LIVE=1`. They live in spec/lib/timekeeping_demo."
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    runtime = IntegratedRuntime.start(root: Rails.root.to_s, env: ENV.to_h)
    groups = []
    begin
      expect(runtime.monolith_url).to match(%r{\Ahttp://127\.0\.0\.1:\d+\z})
      expect(runtime.timekeeping_url).to match(%r{\Ahttp://127\.0\.0\.1:\d+\z})
      expect(runtime.monolith_url == runtime.timekeeping_url).to be(false)
      expect(runtime.credentials).to be_a(TimekeepingDemo::Credentials)
      groups = runtime.process_groups.to_a
      expect(groups.size).to be > 1
      expect(groups.all? { |group| group.is_a?(Integer) && group > 1 }).to be(true)
    ensure
      runtime.stop!
    end

    expect { runtime.stop! }.not_to raise_error
    alive = groups.select do |group|
      Process.kill(0, -group)
      true
    rescue Errno::ESRCH
      false
    end
    expect(alive).to be_empty
  end
end

RSpec.describe "IntegratedRuntime example hooks" do
  # "Examples tagged `:integrated_runtime` start the runtime in a `before(:each)` hook registered after the cleaner and owner-state hooks. They stop it in a `config.after` hook, which runs before the cleaners' `append_after` resets."
  it "an example tagged integrated_runtime runs with the runtime started and the owner state applied, and the runtime is stopped after it" do
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    root = Rails.root.to_s
    seen = {}
    inner = RSpec::Core::ExampleGroup.describe("tagged inner group", :integrated_runtime) do
      it "sees a running runtime" do
        seen[:refused_while_running] =
          begin
            IntegratedRuntime.refuse_if_running!(root:)
            false
          rescue IntegratedRuntime::BootError
            true
          end
        expected_state = TimekeepingOwnerState::SELECTED || TimekeepingOwnerState::DEFAULT_STATE
        seen[:owner_state_kept] =
          TimekeepingOwnership.current.generation == TimekeepingOwnerState.fetch(expected_state).fetch(:generation)
      end
    end
    passed = inner.run(RSpec::Core::NullReporter)
    RSpec.world.example_groups.delete(inner)

    expect(passed).to be(true)
    expect(seen[:refused_while_running]).to be(true)
    expect(seen[:owner_state_kept]).to be(true)
    expect(IntegratedRuntime.refuse_if_running!(root:)).to be_nil
  end
end

RSpec.describe "IntegratedRuntime entry writes", :without_transaction do
  # "After reset in the timekeeping state, a real entry write to the started Timekeeping app succeeds. Use the route from spec/support/timekeeping/client.rb."
  it "after reset in the timekeeping state a real entry write to the started Timekeeping app succeeds" do
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    TimekeepingOwnerState.apply!("timekeeping")
    company = create(:company)
    user = create(:user)
    create(:employment, company:, user:)
    user.add_role(:owner, company)
    project = create(:project, client: create(:client, company:))

    IntegratedRuntime.run(root: Rails.root.to_s, env: ENV.to_h, owner_state: "timekeeping") do |runtime|
      private_key = OpenSSL::PKey::RSA.new(runtime.credentials.private_key_pem)
      token = Timekeeping::UserToken.mint(user:, company:, project_ids: [project.id], private_key:)
      post = Net::HTTP::Post.new(URI.join(runtime.timekeeping_url, "/v1/companies/#{company.id}/entries"))
      post["Authorization"] = "Bearer #{token}"
      post["Content-Type"] = "application/json"
      post["Ownership-Generation"] = TimekeepingOwnerState.fetch("timekeeping").fetch(:admission_generation).to_s
      post["Idempotency-Key"] = SecureRandom.uuid
      post.body = JSON.generate("project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 45.0,
                                "note" => "Integrated runtime write", "source" => "manual", "source_metadata" => {})
      uri = post.uri
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(post) }

      expect(response).to be_a(Net::HTTPSuccess)
    end
  end
end

RSpec.describe "IntegratedRuntime against the real demo runtime" do
  # "A failed example still kills the process group, including every app group the supervisor started, even when the launcher died before readiness"
  it "run leaves no launcher or recorded app group alive when the inner block fails" do
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    groups_file = Rails.root.join("tmp", "timekeeping-demo", "process_groups").to_s
    recorded = []
    expect do
      IntegratedRuntime.run(root: Rails.root.to_s, env: ENV.to_h) do |runtime|
        recorded = (runtime.process_groups + IntegratedRuntime.parse_groups(File.read(groups_file))).uniq
        raise "inner example failed"
      end
    end.to raise_error(RuntimeError, "inner example failed")

    # The launcher group alone would not prove the app groups were killed.
    expect(recorded.size).to be > 1
    recorded.each do |pgid|
      expect { Process.kill(0, -pgid) }.to raise_error(Errno::ESRCH)
    end
  end
end

RSpec.describe "IntegratedRuntime live teardown and secrecy" do
  let(:live_runtime_root) { Rails.root.to_s }
  let(:live_runtime_groups_file) { Rails.root.join("tmp", "timekeeping-demo", "process_groups").to_s }

  before do
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    WebMock.disable_net_connect!(allow_localhost: true)
  end

  # The supervisor's prepare step records one db:prepare group per
  # application before run starts any app, so more lines than that means at
  # least one app group is recorded.
  def live_runtime_app_group_recorded?
    IntegratedRuntime.parse_groups(File.read(live_runtime_groups_file)).size >
      TimekeepingDemo::RuntimePlan::APPLICATIONS.size
  rescue Errno::ENOENT
    false
  end

  # Every app is spawned directly by the launcher, so a recorded group
  # leader's parent is the launcher. Field 4 of /proc/<pid>/stat, counted
  # after the parenthesised command name, is the parent pid.
  def live_runtime_parent_of(pid)
    Integer(File.read("/proc/#{pid}/stat").rpartition(")").last.split.fetch(1), 10)
  end

  def live_runtime_group_gone?(pgid)
    Process.kill(0, -pgid)
    false
  rescue Errno::ESRCH
    true
  end

  def live_runtime_metrics_status(runtime)
    uri = URI.join(runtime.timekeeping_url, "/internal/v1/metrics")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{runtime.credentials.service_token}"
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }.code
  end

  # "Kill the launcher with KILL before readiness. After `stop!`, no recorded group is alive: `Process.kill(0, -pgid)` raises `Errno::ESRCH`."
  it "start stops every recorded app group when the launcher is killed with KILL before the runtime is ready" do
    killer = Thread.new do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + IntegratedRuntime::BOOT_TIMEOUT_SECONDS
      sleep 0.05 until live_runtime_app_group_recorded? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      app_group = IntegratedRuntime.parse_groups(File.read(live_runtime_groups_file)).last
      launcher = live_runtime_parent_of(app_group)
      Process.kill("KILL", -launcher)
      launcher
    end

    expect { IntegratedRuntime.start(root: live_runtime_root, env: ENV.to_h) }
      .to raise_error(IntegratedRuntime::BootError, /launcher exited before the runtime was ready/)
    launcher = killer.value

    recorded = IntegratedRuntime.parse_groups(File.read(live_runtime_groups_file))
    # Proves an app group, not only the launcher, existed when the launcher died.
    expect(recorded.size).to be > TimekeepingDemo::RuntimePlan::APPLICATIONS.size
    expect(([launcher] + recorded).all? { |pgid| live_runtime_group_gone?(pgid) }).to be(true)
  ensure
    killer&.kill
  end

  # "versions.json, the captured stdout and stderr, and the runtime output hold none of the values."
  it "versions.json, the runtime output and the groups file hold none of the harness credential values" do
    values = []
    outputs = {}
    IntegratedRuntime.run(root: live_runtime_root, env: ENV.to_h) do |runtime|
      credentials = runtime.credentials
      values = [credentials.private_key_pem, credentials.public_key_pem, credentials.service_token]
      # The launcher's combined stdout and stderr; the harness deletes it on stop.
      outputs[:runtime_output] = File.read(runtime.instance_variable_get(:@log).path)
    end
    outputs[:versions] = File.read(Rails.root.join("tmp", "timekeeping-demo", "versions.json"))
    outputs[:process_groups] = File.read(live_runtime_groups_file)

    expect(values.all? { |value| value.is_a?(String) && !value.empty? }).to be(true)
    leaks = outputs.transform_values { |text| values.any? { |value| text.include?(value) } }
    expect(leaks).to eq(runtime_output: false, versions: false, process_groups: false)
  end

  it "a second start is ready after a runtime whose groups were all killed with KILL" do
    first = IntegratedRuntime.start(root: live_runtime_root, env: ENV.to_h)
    begin
      first.process_groups.each { |pgid| IntegratedRuntime.kill_group(pgid) }
    ensure
      first.stop!
    end

    second = IntegratedRuntime.start(root: live_runtime_root, env: ENV.to_h)
    begin
      expect(live_runtime_metrics_status(second)).to eq("200")
    ensure
      second.stop!
    end
  end
end

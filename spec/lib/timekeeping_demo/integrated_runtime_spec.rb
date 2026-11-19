# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"

# Parallel CI workers connect to miru_web_test_N, a name the monolith guard
# refuses by design. Examples that are not about that guard pin a name it
# accepts, so they test the same path on every worker.
RSpec.shared_context "integrated runtime on an accepted monolith test database" do
  before { allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test") }
end

RSpec.describe IntegratedRuntime do
  it "launch passes harness credentials only in the spawn env, overriding stale ones, and never in argv or ENV" do
    harness = TimekeepingDemo::Credentials.generate
    stale = TimekeepingDemo::Credentials.generate
    env_before = ENV.to_h

    spawn_env, argv, options = described_class.launch(
      root: Rails.root.to_s, env: ENV.to_h.merge(stale.to_env), credentials: harness,
      ports: { monolith: 4101, timekeeping: 4102 }
    )

    # "The harness passes credentials only in the `Process.spawn` env hash, never in the test process ENV or argv."
    harness.to_env.each do |key, value|
      expect(spawn_env[key] == value).to be(true)
    end
    stale.to_env.each_value { |value| expect(spawn_env.value?(value)).to be(false) }
    secrets = harness.to_env.values
    expect(argv.any? { |argument| secrets.any? { |secret| argument.to_s.include?(secret) } }).to be(false)
    expect(options.to_s.then { |text| secrets.any? { |secret| text.include?(secret) } }).to be(false)
    expect(ENV.to_h == env_before).to be(true)
    TimekeepingDemo::Credentials::ENV_KEYS.each_value do |key|
      expect(ENV[key].nil? || !secrets.include?(ENV[key])).to be(true)
    end
    expect(argv.last).to eq("up")
    expect(argv.any? { |argument| argument.end_with?("bin/timekeeping-demo") }).to be(true)
    # "It starts `bin/timekeeping-demo up` in its own process group"
    expect(options[:pgroup]).to be(true)
  end

  it "parse_groups reads back only whole recorded group ids above 1, so teardown cannot signal its own group or every process" do
    # A launcher killed mid-write can leave a blank or partial last line; "".to_i is 0,
    # and Process.kill(sig, -0) would hit the rspec process group, -1 every user process.
    text = "4242\n\n0\n1\n-7\n-5\nabc\n12x\n 99\n4243\n4343\n9001\n31337\n5"

    # The final "5" has no newline, so it may be a partial write and is skipped.
    expect(described_class.parse_groups(text)).to eq([4242, 4243, 4343, 9001, 31_337])
    expect(described_class.parse_groups("")).to eq([])
  end

  it "refuse_if_running! refuses while the groups file lists a live group, leaves the file untouched, and passes once it is gone" do
    Dir.mktmpdir("integrated-runtime-root") do |root|
      groups_path = File.join(root, "tmp", "timekeeping-demo", "process_groups")
      FileUtils.mkdir_p(File.dirname(groups_path))
      pid = Process.spawn("sleep", "60", pgroup: true)
      begin
        baseline = "#{pid}\n"
        File.write(groups_path, baseline)
        expect(File.read(groups_path)).to eq(baseline)

        # "Refuse to start while the groups file lists a live group."
        expect { described_class.refuse_if_running!(root:) }.to raise_error(IntegratedRuntime::BootError)
        # The refusal leaves the record in place, so a later teardown still finds the live group.
        expect(File.read(groups_path)).to eq(baseline)
      ensure
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
        Process.wait(pid)
      end

      expect(described_class.refuse_if_running!(root:)).to be_nil
    end
  end
end

RSpec.describe IntegratedRuntime do
  include_context "integrated runtime on an accepted monolith test database"

  it "start raises a boot error that names no environment value, child output or credential when the launcher dies during boot" do
    sentinel = "harness-sentinel-#{SecureRandom.hex(8)}"
    Dir.mktmpdir("integrated-runtime-root") do |root|
      FileUtils.cp(Rails.root.join("Procfile.timekeeping"), root)
      FileUtils.mkdir_p(File.join(root, "bin"))
      FileUtils.mkdir_p(File.join(root, "timekeeping", "bin"))
      File.write(File.join(root, "timekeeping", "Gemfile"), "")
      File.write(File.join(root, "timekeeping", "bin", "rails"), "#!/bin/sh\nexit 0\n")
      # The fake launcher prints its whole environment, credentials included, then dies.
      File.write(File.join(root, "bin", "timekeeping-demo"), "#!/bin/sh\necho #{sentinel}\nenv\nenv 1>&2\nexit 1\n")
      FileUtils.chmod(0o755, [File.join(root, "bin", "timekeeping-demo"), File.join(root, "timekeeping", "bin", "rails")])
      env = ENV.to_h.merge(
        "SENTINEL_SETTING" => sentinel,
        "DATABASE_URL" => "postgres://monolith_harness_user@127.0.0.1:5432/miru_harness_test",
        "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_harness_user@127.0.0.1:5432/timekeeping_harness_missing_test"
      )
      env_before = ENV.to_h
      # The reset is not under test here; stubbing it makes sure the error comes from the launcher.
      allow(TimekeepingDatabaseReset).to receive(:reset!)
      # A ledger of its own, so this fake boot never activates the suite's shared queue ledger.
      ledger = instance_spy(TimekeepingQueueLedger::Session)
      expect(TimekeepingQueueLedger.session).not_to receive(:activate!)
      expect(TimekeepingQueueLedger.session).not_to receive(:open_window!)

      error = nil
      output = capture_harness_output do
        described_class.start(root:, env:, ledger:)
      rescue StandardError => e
        error = e
      end

      # "Boot errors name the app and the timeout only, never the environment or the child's output."
      expect(error).to be_a(IntegratedRuntime::BootError)
      message = error.message
      expect(message.include?(sentinel)).to be(false)
      expect(message.include?("PRIVATE KEY")).to be(false)
      expect(message.include?("PUBLIC KEY")).to be(false)
      expect(message.include?("127.0.0.1:5432")).to be(false)
      expect(message.include?("launcher exited")).to be(true)
      expect(message.include?("boot timeout #{IntegratedRuntime::BOOT_TIMEOUT_SECONDS} s")).to be(true)
      # "Never log, print or write them to versions.json."
      expect(output.include?(sentinel)).to be(false)
      expect(output.include?("PRIVATE KEY")).to be(false)
      expect(ENV.to_h == env_before).to be(true)
      # "A suite with no active ledger runs unchanged": the injected ledger, not the shared one, opened the window.
      expect(ledger).to have_received(:activate!)
      expect(ledger).to have_received(:open_window!)
    end
  end

  def capture_harness_output
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    $stdout.string + $stderr.string
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end
end

RSpec.describe "IntegratedRuntime" do
  it "start refuses a monolith database whose name does not end in _test before cleaning or spawning anything" do
    monolith_config = instance_double(ActiveRecord::DatabaseConfigurations::HashConfig, database: "miru_development")
    allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(monolith_config)
    allow(TestDatabaseCleanup).to receive(:delete_all_committed!)
    allow(TimekeepingDatabaseReset).to receive(:reset!)
    allow(Process).to receive(:spawn).and_call_original
    env = {
      "PATH" => ENV.fetch("PATH", ""),
      "DB_USER" => "harness_guard_monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://harness_guard_timekeeping_user@127.0.0.1:5432/timekeeping_harness_guard_test"
    }

    # "Refuse to clean a monolith database whose name does not end in `_test`, using `TestDatabaseGuard.require_test_database!`."
    expect { IntegratedRuntime.start(root: Rails.root.to_s, env:) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(TestDatabaseCleanup).not_to have_received(:delete_all_committed!)
    expect(TimekeepingDatabaseReset).not_to have_received(:reset!)
    expect(Process).not_to have_received(:spawn)
  end
end

RSpec.describe "IntegratedRuntime" do
  include_context "integrated runtime on an accepted monolith test database"

  it "start refuses a Timekeeping database whose name does not end in _test before db:prepare runs" do
    allow(TimekeepingDatabaseReset).to receive(:reset!)
    allow(Process).to receive(:spawn).and_call_original
    env = {
      "PATH" => ENV.fetch("PATH", ""),
      "DB_USER" => "harness_prepare_monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://harness_prepare_timekeeping_user@127.0.0.1:5432/timekeeping_development"
    }

    # A pending migration run against a real database cannot be undone, so the name is checked first.
    expect { IntegratedRuntime.start(root: Rails.root.to_s, env:) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(Process).not_to have_received(:spawn)
    expect(TimekeepingDatabaseReset).not_to have_received(:reset!)
  end

  it "start refuses a caller DATABASE_URL naming a non-test monolith database before anything is spawned" do
    allow(TimekeepingDatabaseReset).to receive(:reset!)
    allow(Process).to receive(:spawn).and_call_original
    env = {
      "PATH" => ENV.fetch("PATH", ""),
      "DATABASE_URL" => "postgres://harness_child_monolith_user@127.0.0.1:5432/miru_web_development",
      "TIMEKEEPING_DATABASE_URL" => "postgres://harness_child_timekeeping_user@127.0.0.1:5432/timekeeping_child_guard_test"
    }

    # The launcher's monolith uses the caller's DATABASE_URL, so that database is the one that must end in _test.
    expect { IntegratedRuntime.start(root: Rails.root.to_s, env:) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /miru_web_development/)
    expect(Process).not_to have_received(:spawn)
    expect(TimekeepingDatabaseReset).not_to have_received(:reset!)
  end
end

RSpec.describe "IntegratedRuntime" do
  include_context "integrated runtime on an accepted monolith test database"

  it "start prepares the Timekeeping database before resetting it for the owner state and before launching" do
    steps = []
    stop_after_reset = Class.new(StandardError)
    allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **_options|
      argv = args.drop_while { |arg| arg.is_a?(Hash) }.flatten.map(&:to_s)
      steps << (argv.include?("db:prepare") ? :prepare_timekeeping : :other_spawn)
      original.call("true")
    end
    allow(TimekeepingDatabaseReset).to receive(:reset!) do |state_name, env:|
      steps << [:reset, state_name, env.key?("TIMEKEEPING_DATABASE_URL")]
      raise stop_after_reset
    end
    env = {
      "PATH" => ENV.fetch("PATH", ""),
      "HOME" => ENV.fetch("HOME", ""),
      "DB_USER" => "harness_order_monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://harness_order_timekeeping_user@127.0.0.1:5432/timekeeping_harness_order_test"
    }

    # "Before starting, prepare the Timekeeping database as spec/support/timekeeping/live_instance.rb does.
    #  Then call `TimekeepingDatabaseReset.reset!` from the owner state slice."
    expect { IntegratedRuntime.start(root: Rails.root.to_s, env:, owner_state: "timekeeping") }
      .to raise_error(stop_after_reset)
    expect(steps.first).to eq(:prepare_timekeeping)
    expect(steps.last).to eq([:reset, "timekeeping", true])
    expect(steps).not_to include(:other_spawn)
  end
end

RSpec.describe "IntegratedRuntime.start refusal" do
  # "Pick free ports with `TCPServer`. Refuse to start while the groups file lists a live group."
  it "start refuses before spawning or truncating while the groups file lists a live group" do
    survivor = Process.spawn("sleep", "60", pgroup: true)
    Dir.mktmpdir("integrated-runtime-start-refusal") do |root|
      groups_file = File.join(root, "tmp", "timekeeping-demo", "process_groups")
      FileUtils.mkdir_p(File.dirname(groups_file))
      File.write(groups_file, "#{survivor}\n")
      env = { "TIMEKEEPING_DATABASE_URL" => "postgres:///timekeeping_start_refusal_test" }
      allow(Process).to receive(:spawn).and_call_original

      expect { IntegratedRuntime.start(root:, env:) }.to raise_error(IntegratedRuntime::BootError)

      expect(Process).not_to have_received(:spawn)
      expect(File.read(groups_file)).to eq("#{survivor}\n")
      expect(Process.kill(0, -survivor)).to eq(1)
    end
  ensure
    if survivor
      begin
        Process.kill("KILL", -survivor)
      rescue Errno::ESRCH
        nil
      end
      Process.wait(survivor)
    end
  end
end

RSpec.describe IntegratedRuntime do
  include_context "integrated runtime on an accepted monolith test database"

  def integrated_runtime_teardown_fixture(root)
    credentials = TimekeepingDemo::Credentials.generate
    described_class.new(root:, env: {}, credentials:, ports: { monolith: 40_011, timekeeping: 40_012 })
  end

  it "stop! kills a recorded app group whose launcher already exited, and a second stop! does nothing" do
    Dir.mktmpdir("integrated-runtime-teardown") do |root|
      groups_file = File.join(root, "tmp", "timekeeping-demo", "process_groups")
      FileUtils.mkdir_p(File.dirname(groups_file))
      # Ignores TERM, so only the KILL after the deadline can end it.
      app_group = Process.spawn("sh", "-c", "trap '' TERM; sleep 60", pgroup: true)
      launcher = Process.spawn("true", pgroup: true)
      Process.wait(launcher)
      File.write(groups_file, "#{app_group}\n")
      runtime = integrated_runtime_teardown_fixture(root)
      runtime.instance_variable_set(:@launcher, launcher)
      stub_const("TimekeepingDemo::Supervisor::STOP_GRACE_SECONDS", 0)
      stub_const("IntegratedRuntime::STOP_MARGIN_SECONDS", 1)

      begin
        runtime.stop!

        # "After `stop!`, no recorded group is alive: `Process.kill(0, -pgid)` raises `Errno::ESRCH`."
        expect { Process.kill(0, -app_group) }.to raise_error(Errno::ESRCH)
        expect { runtime.stop! }.not_to raise_error
      ensure
        described_class.kill_group(app_group)
      end
    end
  end

  it "prepares Timekeeping with only its own planned environment, so an inherited private key never reaches it" do
    inherited = TimekeepingDemo::Credentials.generate
    private_key_key = TimekeepingDemo::Credentials::ENV_KEYS.fetch(:private_key_pem)
    spawned = []
    allow(Process).to receive(:spawn).and_wrap_original do |original, env, *argv, **options|
      spawned << { env:, argv:, options: }
      original.call("true")
    end
    stop_after_prepare = Class.new(StandardError)
    allow(TimekeepingDatabaseReset).to receive(:reset!).and_raise(stop_after_prepare)
    # The caller's environment holds a private key, as a developer's shell might.
    env = ENV.to_h.merge(
      private_key_key => inherited.private_key_pem,
      "DB_USER" => "harness_isolation_monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://harness_isolation_timekeeping_user@127.0.0.1:5432/timekeeping_isolation_test"
    )

    expect { described_class.start(root: Rails.root.to_s, env:) }.to raise_error(stop_after_prepare)

    prepare = spawned.find { |call| call[:argv].include?("db:prepare") }
    expect(prepare.nil?).to be(false)
    expect(prepare[:env].key?(private_key_key)).to be(false)
    expect(prepare[:env].value?(inherited.private_key_pem)).to be(false)
    expect(prepare[:options][:unsetenv_others]).to be(true)
  end

  it "an example tagged integrated_runtime checks for a live runtime, cleans, starts, and stops before cleaning again" do
    steps = []
    runtime = instance_double(described_class)
    allow(described_class).to receive(:refuse_if_running!) { steps << :refuse_if_running }
    allow(TestDatabaseCleanup).to receive(:delete_all_committed!) { steps << :clean_monolith }
    allow(described_class).to receive(:start) do
      steps << :start
      runtime
    end
    allow(runtime).to receive(:stop!) { steps << :stop }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return("1")

    inner = RSpec::Core::ExampleGroup.describe("integrated runtime hook order", :integrated_runtime) do
      it("runs between the hooks") { steps << :example }
    end
    passed = inner.run(RSpec::Core::NullReporter)
    RSpec.world.example_groups.delete(inner)

    # "Examples tagged `:integrated_runtime` start the runtime in a `before(:each)` hook ... They stop it in a
    #  `config.after` hook, which runs before the cleaners' `append_after` resets."
    expect(passed).to be(true)
    expect(steps).to eq(%i[refuse_if_running clean_monolith start example stop clean_monolith])
  end

  it "an integrated_runtime example refused because another runtime is live cleans and starts nothing" do
    steps = []
    allow(described_class).to receive(:refuse_if_running!).and_raise(IntegratedRuntime::BootError, "already running")
    allow(TestDatabaseCleanup).to receive(:delete_all_committed!) { steps << :clean_monolith }
    allow(TestDatabaseCleanup).to receive(:delete_operation_ledger_rows!) { steps << :delete_ledger }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :truncate }
    allow(described_class).to receive(:start) { steps << :start }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return("1")

    # :without_transaction adds the truncation hooks before and after, which must not run either.
    inner = RSpec::Core::ExampleGroup.describe("integrated runtime refused", :integrated_runtime, :without_transaction) do
      it("must not run") { steps << :example }
    end
    passed = inner.run(RSpec::Core::NullReporter)
    RSpec.world.example_groups.delete(inner)

    # "Refuse to start while the groups file lists a live group."
    expect(passed).to be(false)
    expect(steps).to eq([])
  end

  it "an integrated_runtime example without TIMEKEEPING_LIVE=1 is skipped before any check, clean or start" do
    steps = []
    allow(described_class).to receive(:refuse_if_running!) { steps << :refuse_if_running }
    allow(TestDatabaseCleanup).to receive(:delete_all_committed!) { steps << :clean_monolith }
    allow(described_class).to receive(:start) { steps << :start }
    allow(TestDatabaseCleanup).to receive(:delete_operation_ledger_rows!) { steps << :delete_ledger }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :truncate }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return(nil)

    inner = RSpec::Core::ExampleGroup.describe("integrated runtime without the live flag", :integrated_runtime,
                                               :without_transaction) do
      it("is skipped") { steps << :example }
    end
    inner.run(RSpec::Core::NullReporter)
    pending_example = inner.examples.first
    RSpec.world.example_groups.delete(inner)

    # "Live tests skip unless `TIMEKEEPING_LIVE=1`."
    expect(pending_example.execution_result.status).to eq(:pending)
    expect(steps).to eq([])
  end

  it "an integrated_runtime example whose runtime fails to stop runs no reset afterwards" do
    steps = []
    runtime = instance_double(described_class)
    allow(described_class).to receive(:refuse_if_running!)
    allow(described_class).to receive(:start).and_return(runtime)
    allow(runtime).to receive(:stop!).and_raise(IntegratedRuntime::BootError, "groups still alive after KILL")
    allow(TestDatabaseCleanup).to receive(:delete_all_committed!) { steps << :clean_monolith }
    allow(TestDatabaseCleanup).to receive(:delete_operation_ledger_rows!) { steps << :delete_ledger }
    allow(DatabaseCleaner).to receive(:clean_with) { steps << :truncate }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return("1")

    inner = RSpec::Core::ExampleGroup.describe("integrated runtime stop failure", :integrated_runtime,
                                               :without_transaction) do
      it("runs") { steps << :example }
    end
    passed = inner.run(RSpec::Core::NullReporter)
    RSpec.world.example_groups.delete(inner)

    # "No worker or scheduler then runs during a reset": nothing resets beside a group that outlived stop!.
    expect(passed).to be(false)
    expect(steps).to eq(%i[truncate clean_monolith example])
  end

  it "boot! stops its launcher when readiness is interrupted, so the caller never holds a running orphan" do
    Dir.mktmpdir("integrated-runtime-interrupt") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      launcher_path = File.join(root, "bin", "timekeeping-demo")
      File.write(launcher_path, "#!/bin/sh\nexec sleep 60\n")
      File.chmod(0o755, launcher_path)
      runtime = described_class.new(root:, env: { "PATH" => ENV.fetch("PATH") },
                                    credentials: TimekeepingDemo::Credentials.generate,
                                    ports: { monolith: 40_021, timekeeping: 40_022 })
      allow(runtime).to receive(:wait_until_ready).and_raise(Interrupt)
      stub_const("TimekeepingDemo::Supervisor::STOP_GRACE_SECONDS", 1)
      stub_const("IntegratedRuntime::STOP_MARGIN_SECONDS", 1)

      expect { runtime.boot! }.to raise_error(Interrupt)
      launcher = runtime.process_groups.first
      expect(launcher.nil?).to be(false)
      expect { Process.kill(0, -launcher) }.to raise_error(Errno::ESRCH)
    end
  end

  it "start bounds a stalled Timekeeping db:prepare by the boot timeout and kills it" do
    Dir.mktmpdir("integrated-runtime-prepare-timeout") do |root|
      FileUtils.cp(Rails.root.join("Procfile.timekeeping"), root)
      FileUtils.mkdir_p(File.join(root, "timekeeping", "bin"))
      File.write(File.join(root, "timekeeping", "Gemfile"), "")
      rails = File.join(root, "timekeeping", "bin", "rails")
      File.write(rails, "#!/bin/sh\nexec sleep 60\n")
      File.chmod(0o755, rails)
      stub_const("IntegratedRuntime::BOOT_TIMEOUT_SECONDS", 1)
      allow(TimekeepingDatabaseReset).to receive(:reset!)
      spawned = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **options|
        original.call(*args, **options).tap { |pid| spawned << pid }
      end
      env = ENV.to_h.except("DATABASE_URL").merge(
        "DB_USER" => "harness_timeout_monolith_user",
        "TIMEKEEPING_DATABASE_URL" => "postgres://harness_timeout_timekeeping_user@127.0.0.1:5432/timekeeping_timeout_test"
      )

      expect { described_class.start(root:, env:) }
        .to raise_error(IntegratedRuntime::BootError, "timekeeping db:prepare did not finish (boot timeout 1 s)")
      expect(spawned.size).to eq(1)
      expect { Process.kill(0, -spawned.first) }.to raise_error(Errno::ESRCH)
      expect(TimekeepingDatabaseReset).not_to have_received(:reset!)
    end
  end

  it "start refuses a Timekeeping URL whose path names a non-test database behind a _test dbname parameter" do
    allow(TimekeepingDatabaseReset).to receive(:reset!)
    allow(Process).to receive(:spawn).and_call_original
    env = {
      "PATH" => ENV.fetch("PATH", ""),
      "TIMEKEEPING_DATABASE_URL" =>
        "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"
    }

    # libpq reads the parameter, Rails reads the path: db:prepare would migrate timekeeping_development.
    expect { described_class.start(root: Rails.root.to_s, env:) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
    expect(Process).not_to have_received(:spawn)
    expect(TimekeepingDatabaseReset).not_to have_received(:reset!)
  end
end

RSpec.describe IntegratedRuntime, ".require_test_database_url!" do
  # The collector probe writes rows that break the queue rule on purpose, so it must never reach a
  # database that is not a test database. Active Record reads the URL's path; libpq, which PG.connect
  # uses to insert and delete the probe's rows, reads its dbname parameter.
  it "is public" do
    expect(described_class.public_methods).to include(:require_test_database_url!)
  end

  it "returns nil for a URL that names a _test database under both readings" do
    url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_collector_guard_test"

    expect(described_class.require_test_database_url!(url)).to be_nil
  end

  it "refuses a URL whose path names a non-test database" do
    expect { described_class.require_test_database_url!("postgres://localhost:5432/timekeeping_collector_rows_demo") }
      .to raise_error(TestDatabaseGuard::NotATestDatabase)
  end

  it "refuses a URL whose path names a non-test database behind a _test dbname parameter" do
    url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_development?dbname=timekeeping_collector_guard_test"

    expect { described_class.require_test_database_url!(url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
  end

  it "refuses a URL whose dbname parameter names a non-test database behind a _test path" do
    url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_collector_guard_test?dbname=timekeeping_production"

    expect { described_class.require_test_database_url!(url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_production/)
  end
end

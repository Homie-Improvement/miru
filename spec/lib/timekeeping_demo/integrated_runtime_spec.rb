# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"

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
  end

  it "parse_groups never answers a group id that would signal the test process group or every process" do
    groups = described_class.parse_groups("4242\n\n0\n1\nabc\n-7\n4243\n42")

    expect(groups).to all(be > 1)
    expect(groups).to include(4242, 4243)
    expect(groups).not_to include(0, 1, -7)
  end
end

RSpec.describe IntegratedRuntime do
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

      error = nil
      output = capture_harness_output do
        described_class.start(root:, env:)
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
      expect(message.match?(/launcher|monolith|timekeeping/)).to be(true)
      # "Never log, print or write them to versions.json."
      expect(output.include?(sentinel)).to be(false)
      expect(output.include?("PRIVATE KEY")).to be(false)
      expect(ENV.to_h == env_before).to be(true)
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
  it "refuse_if_running! refuses while the groups file lists a live group and allows a start once it is gone" do
    Dir.mktmpdir("integrated-runtime-root") do |root|
      groups_dir = File.join(root, "tmp", "timekeeping-demo")
      FileUtils.mkdir_p(groups_dir)
      groups_path = File.join(groups_dir, "process_groups")
      pid = Process.spawn("sleep", "60", pgroup: true)
      begin
        File.write(groups_path, "#{pid}\n")

        # "Refuse to start while the groups file lists a live group."
        expect { IntegratedRuntime.refuse_if_running!(root:) }.to raise_error(IntegratedRuntime::BootError)
        # The refusal leaves the record in place, so a later teardown still finds the live group.
        expect(File.read(groups_path)).to eq("#{pid}\n")
      ensure
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
        Process.wait(pid)
      end

      expect(IntegratedRuntime.refuse_if_running!(root:)).to be_nil
    end
  end
end

RSpec.describe "IntegratedRuntime" do
  it "parse_groups reads back only whole recorded group ids from a torn groups file" do
    # A launcher killed mid-write can leave a blank or partial last line; 0 and 1
    # would signal the caller's own group or every process the user owns.
    text = "4242\n\n0\n1\nabc\n4343\n12x\n"

    expect(IntegratedRuntime.parse_groups(text)).to eq([4242, 4343])
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
end

RSpec.describe "IntegratedRuntime" do
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

RSpec.describe IntegratedRuntime do
  it "parse_groups keeps only recorded group ids above 1 and skips blank, non-numeric, 0 and 1 lines" do
    # Signalling -0 would hit the test process's own group and -1 every process the user owns.
    text = "4242\n\nabc\n0\n1\n-5\n9001\n12x\n"

    expect(described_class.parse_groups(text)).to eq([4242, 9001])
    expect(described_class.parse_groups("")).to eq([])
  end
end

RSpec.describe IntegratedRuntime do
  it "refuse_if_running! raises while the groups file lists a live group and passes once it is gone" do
    Dir.mktmpdir("integrated-runtime-root") do |root|
      groups_path = File.join(root, "tmp", "timekeeping-demo", "process_groups")
      FileUtils.mkdir_p(File.dirname(groups_path))
      pid = Process.spawn("sleep", "60", pgroup: true)
      begin
        File.write(groups_path, "#{pid}\n")

        # "Refuse to start while the groups file lists a live group."
        expect { described_class.refuse_if_running!(root:) }.to raise_error(IntegratedRuntime::BootError)
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
  it "launch passes the harness credentials only in the spawn env hash, over stale ones, and never in argv or ENV" do
    harness = TimekeepingDemo::Credentials.generate
    stale = TimekeepingDemo::Credentials.generate
    env = {
      "PATH" => ENV.fetch("PATH"),
      "TIMEKEEPING_TOKEN_PRIVATE_KEY" => stale.private_key_pem,
      "TIMEKEEPING_TOKEN_PUBLIC_KEY" => stale.public_key_pem,
      "TIMEKEEPING_SERVICE_TOKEN" => stale.service_token
    }
    env_before = ENV.to_h

    spawn_env, argv, options = described_class.launch(root: Rails.root.to_s, env:, credentials: harness,
                                                      ports: { monolith: 3301, timekeeping: 3401 })

    # "The harness passes credentials only in the `Process.spawn` env hash, never in the test process ENV or argv."
    expect(spawn_env["TIMEKEEPING_TOKEN_PRIVATE_KEY"] == harness.private_key_pem).to be(true)
    expect(spawn_env["TIMEKEEPING_TOKEN_PUBLIC_KEY"] == harness.public_key_pem).to be(true)
    expect(spawn_env["TIMEKEEPING_SERVICE_TOKEN"] == harness.service_token).to be(true)
    secrets = [harness.private_key_pem, harness.public_key_pem, harness.service_token]
    expect(argv.any? { |arg| secrets.any? { |secret| arg.include?(secret) } }).to be(false)
    expect(argv.last).to eq("up")
    expect(argv.any? { |arg| arg.end_with?("bin/timekeeping-demo") }).to be(true)
    expect(ENV.to_h == env_before).to be(true)
    # "It starts `bin/timekeeping-demo up` in its own process group"
    expect(options[:pgroup]).to be(true)
  end
end

RSpec.describe IntegratedRuntime do
  it "parse_groups never yields 0, 1 or a torn line, so teardown cannot signal its own group or every process" do
    # A launcher killed mid-write can leave a blank or partial last line; "".to_i is 0,
    # and Process.kill(sig, -0) would hit the rspec process group, -1 every user process.
    text = "4242\n\n0\n1\n-7\nabc\n12x\n 99\n31337\n5"

    expect(described_class.parse_groups(text)).to eq([4242, 31_337, 5])
  end
end

RSpec.describe IntegratedRuntime do
  it "refuse_if_running! raises while the groups file lists a live group left by an earlier run" do
    Dir.mktmpdir do |root|
      groups_dir = File.join(root, "tmp", "timekeeping-demo")
      FileUtils.mkdir_p(groups_dir)
      groups_file = File.join(groups_dir, "process_groups")
      survivor = Process.spawn("sleep", "60", pgroup: true)
      begin
        File.write(groups_file, "#{survivor}\n")

        # "Refuse to start while the groups file lists a live group."
        expect { described_class.refuse_if_running!(root:) }.to raise_error(IntegratedRuntime::BootError)
        expect(File.read(groups_file)).to eq("#{survivor}\n")
      ensure
        Process.kill("KILL", -survivor)
        Process.wait(survivor)
      end

      expect(described_class.refuse_if_running!(root:)).to be_nil
    end
  end
end

RSpec.describe IntegratedRuntime do
  it "launch overrides stale credentials in the caller env and keeps every value out of argv and ENV" do
    stale = TimekeepingDemo::Credentials.generate.to_env
    harness = TimekeepingDemo::Credentials.generate
    env_before = ENV.to_h

    spawn_env, argv, options = described_class.launch(
      root: Rails.root.to_s, env: ENV.to_h.merge(stale), credentials: harness,
      ports: { monolith: 40_001, timekeeping: 40_002 }
    )

    # "The harness passes credentials only in the `Process.spawn` env hash, never in the test process ENV or argv."
    expect(harness.to_env.all? { |key, value| spawn_env[key] == value }).to be(true)
    expect(stale.values.any? { |value| spawn_env.value?(value) }).to be(false)
    expect(harness.to_env.values.any? { |value| argv.any? { |arg| arg.to_s.include?(value) } }).to be(false)
    expect(options[:pgroup]).to be(true)
    expect(ENV.to_h == env_before).to be(true)
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
        Process.wait(app_group)

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
end

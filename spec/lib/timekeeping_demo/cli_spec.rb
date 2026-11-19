# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "openssl"
require "stringio"
require "tmpdir"

RSpec.describe TimekeepingDemo::CLI do
  it "writes a versions file that holds no generated credential" do
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare) { |*_args, **_kwargs| true }
    allow(supervisor).to receive(:run) do |specs, *_rest, **_kwargs|
      started.concat(specs)
      0
    end

    Dir.mktmpdir do |state_dir|
      env = {
        "DB_USER" => "monolith_user",
        "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user:tk_db_secret@127.0.0.1:5432/timekeeping_development"
      }
      original = env.keys.index_with { |key| ENV.fetch(key, nil) }
      begin
        env.each { |key, value| ENV[key] = value }
        described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:)
      ensure
        original.each { |key, value| ENV[key] = value }
      end

      # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
      versions_text = File.read(File.join(state_dir, "versions.json"))
      versions = JSON.parse(versions_text)
      expect(versions).to include("monolith", "timekeeping")

      # "No credential is written to a checked-in file."
      expect(versions_text).not_to include("PRIVATE KEY")
      expect(versions_text).not_to include("tk_db_secret")
      secrets = started.flat_map { |spec| spec.env.values_at(*%w[TIMEKEEPING_SERVICE_TOKEN TIMEKEEPING_TOKEN_PRIVATE_KEY]) }.compact
      expect(secrets).not_to be_empty
      secrets.reject(&:empty?).each { |secret| expect(versions_text).not_to include(secret) }
    end
  end

  it "up writes versions.json for both applications, replaces it on a second run, and keeps credentials out of it" do
    governed_keys = %w[TIMEKEEPING_DATABASE_URL DATABASE_URL DB_USER DB_PASS]
    saved = governed_keys.index_with { |key| ENV.fetch(key, nil) }
    root = Rails.root.to_s
    head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    skip "the checkout is not a git work tree" unless status.success?

    begin
      # Different database users on each side, so the launcher's shared-credential refusal does not apply.
      ENV["TIMEKEEPING_DATABASE_URL"] = "postgres://timekeeping_demo_user@127.0.0.1:5432/timekeeping_demo"
      ENV["DATABASE_URL"] = "postgres://monolith_demo_user@127.0.0.1:5432/miru_demo"
      ENV.delete("DB_USER")
      ENV.delete("DB_PASS")

      Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
        versions_path = File.join(state_dir, "versions.json")

        # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
        expect(described_class.run(["up"], root:, supervisor: spy("supervisor"), state_dir:)).to eq(0)
        first_text = File.read(versions_path)
        first = JSON.parse(first_text)
        expect(first.dig("monolith", "revision")).to eq(head.strip)
        expect(first.dig("timekeeping", "revision")).to eq(head.strip)
        expect(first.dig("timekeeping", "tree")).to match(/\A\h{40}\z/)

        # A second run replaces the record rather than appending to it, so the file stays one JSON document.
        expect(described_class.run(["up"], root:, supervisor: spy("supervisor"), state_dir:)).to eq(0)
        second_text = File.read(versions_path)
        expect { JSON.parse(second_text) }.not_to raise_error
        expect(JSON.parse(second_text).keys).to include("monolith", "timekeeping")

        # "No credential is written to a checked-in file."
        [first_text, second_text].each do |text|
          expect(text).not_to include("PRIVATE KEY")
          expect(text).not_to include("PUBLIC KEY")
          expect(text).not_to include("timekeeping_demo_user")
          expect(text).not_to include("monolith_demo_user")
          expect(text).not_to match(/TOKEN|_KEY|_URL/)
        end
      end
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

  it "exits 64 for an unknown verb and starts nothing" do
    # A double with no allowed messages fails the example if the CLI asks it to start anything.
    supervisor = double("timekeeping demo supervisor")

    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      status = nil
      expect do
        status = described_class.run(["bogus"], root: Rails.root.to_s, supervisor:, state_dir:)
      end.to output.to_stdout_from_any_process.or(output.to_stderr_from_any_process)

      expect(status).to eq(64)
      expect(Dir.children(state_dir)).to be_empty
    end
  end
end

RSpec.describe TimekeepingDemo::CLI, "up with a recording supervisor" do
  # Records every call the CLI makes, so no process is started.
  let(:recording_supervisor_class) do
    Class.new do
      attr_reader :specs

      def initialize
        @specs = []
      end

      def method_missing(_name, *args, **_kwargs, &)
        args.flatten.each { |arg| @specs << arg if arg.is_a?(TimekeepingDemo::ProcessSpec) }
        0
      end

      def respond_to_missing?(*)
        true
      end
    end
  end

  it "up hands the supervisor only the two web apps, both relay workers and the invoice-operation worker, and writes versions.json" do
    saved = ENV.to_h.slice("TIMEKEEPING_DATABASE_URL", "DB_USER", "DATABASE_URL")
    supervisor = recording_supervisor_class.new
    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      ENV["TIMEKEEPING_DATABASE_URL"] = "postgres://timekeeping_demo_role@127.0.0.1/timekeeping_demo"
      ENV["DB_USER"] = "monolith_demo_role"
      ENV.delete("DATABASE_URL")

      status = described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:)

      expect(status).to eq(0)
      # "The runtime therefore starts the monolith web app, the Timekeeping web app, the Timekeeping relay worker,
      # the monolith relay worker and the invoice-operation worker, and nothing else."
      names = supervisor.specs.map(&:name).uniq
      expect(names).to contain_exactly("monolith_web", "monolith_relay", "monolith_invoice_operations",
                                       "timekeeping_web", "timekeeping_relay")
      expect(supervisor.specs.flat_map(&:argv)).not_to include("config/solid_queue.yml")

      # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
      versions = JSON.parse(File.read(File.join(state_dir, "versions.json")))
      %w[monolith timekeeping].each do |app|
        expect(versions.fetch(app).fetch("revision")).to match(/\A\h{40}\z/)
      end
    end
  ensure
    %w[TIMEKEEPING_DATABASE_URL DB_USER DATABASE_URL].each { |key| ENV.delete(key) }
    saved&.each { |key, value| ENV[key] = value }
  end
end

RSpec.describe TimekeepingDemo::CLI, "up with caller-supplied credentials" do
  # Starts nothing: collects the process specs the CLI hands the supervisor.
  # prepare spawns real children with each spec's env, so its specs are a
  # credential boundary too and are recorded beside the run specs.
  def caller_credentials_recording_supervisor(started, prepared)
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare) { |specs| prepared.concat(specs) }
    allow(supervisor).to receive(:run) { |specs, **| started.concat(specs) }
    supervisor
  end

  it "up with all three caller credentials gives each app exactly its permitted values and writes none of them out" do
    supplied = TimekeepingDemo::Credentials.generate
    keys = TimekeepingDemo::Credentials::ENV_KEYS
    private_key = keys.fetch(:private_key_pem)
    public_key = keys.fetch(:public_key_pem)
    token = keys.fetch(:service_token)
    caller_env = ENV.to_h.slice("PATH", "HOME", "GEM_HOME", "GEM_PATH").merge(
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo_role@127.0.0.1/timekeeping_demo",
      "DB_USER" => "monolith_demo_role"
    ).merge(supplied.to_env)
    started = []
    prepared = []
    supervisor = caller_credentials_recording_supervisor(started, prepared)
    captured_out = StringIO.new
    captured_err = StringIO.new
    original_out = $stdout
    original_err = $stderr

    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      begin
        $stdout = captured_out
        $stderr = captured_err
        status = described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
      ensure
        $stdout = original_out
        $stderr = original_err
      end
      expect(status).to eq(0)
      # Preparation gets exactly the checked run specs; a boolean, so a failure prints no credential.
      expect(prepared == started).to be(true)

      monolith = started.select { |spec| spec.app == :monolith }
      timekeeping = started.select { |spec| spec.app == :timekeeping }
      expect(monolith).not_to be_empty
      expect(timekeeping).not_to be_empty

      # "`CLI.up` uses credentials from `caller_env` when all are present, and otherwise generates them as before."
      # "`CLI.up` with all three keys in caller_env gives each app exactly its permitted values, byte for byte.
      # The Timekeeping env holds no private key. Comparisons report booleans, never the values."
      monolith.each do |spec|
        expect(spec.env[private_key] == supplied.private_key_pem).to be(true)
        expect(spec.env[token] == supplied.service_token).to be(true)
        expect(spec.env.key?(public_key)).to be(false)
      end
      timekeeping.each do |spec|
        expect(spec.env[public_key] == supplied.public_key_pem).to be(true)
        expect(spec.env[token] == supplied.service_token).to be(true)
        # "Timekeeping gets the public key and the token, and never the private key."
        expect(spec.env.key?(private_key)).to be(false)
        expect(spec.env.values.any? { |value| value == supplied.private_key_pem }).to be(false)
      end

      # "Never log, print or write them to versions.json."
      # "versions.json, the captured stdout and stderr, and the runtime output hold none of the values."
      versions_text = File.read(File.join(state_dir, "versions.json"))
      secrets = supplied.to_env.values
      [versions_text, captured_out.string, captured_err.string].each do |text|
        expect(secrets.any? { |secret| text.include?(secret) }).to be(false)
      end
    end
  end

  it "up with a partial or blank caller set starts the apps with one fresh matching set and no supplied value" do
    keys = TimekeepingDemo::Credentials::ENV_KEYS
    private_key = keys.fetch(:private_key_pem)
    public_key = keys.fetch(:public_key_pem)
    token = keys.fetch(:service_token)
    supplied = TimekeepingDemo::Credentials.generate.to_env
    # The inherited environment minus the credential keys, so every other caller value is in play.
    base_env = ENV.to_h.except(*keys.values).merge(
      "DB_USER" => "monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user@127.0.0.1:5432/timekeeping_test"
    )
    variants = keys.values.flat_map do |key|
      [["#{key} missing", supplied.except(key)],
       ["#{key} empty", supplied.merge(key => "")],
       ["#{key} whitespace", supplied.merge(key => "  ")]]
    end

    variants.each do |label, credential_env|
      started = []
      prepared = []
      supervisor = caller_credentials_recording_supervisor(started, prepared)
      status = Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
        described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:,
                                    caller_env: base_env.merge(credential_env))
      end

      expect(status).to eq(0), "expected status 0 with #{label}"
      expect(prepared == started).to be(true), "expected preparation to get the run specs with #{label}"
      monolith = started.select { |spec| spec.app == :monolith }
      timekeeping = started.select { |spec| spec.app == :timekeeping }
      expect(monolith.empty? || timekeeping.empty?).to be(false), "expected both apps to start with #{label}"

      # "`CLI.up` uses `Credentials.from_env(caller_env) || Credentials.generate`. A partial or blank set therefore
      # gets a whole fresh set and is never mixed with supplied values."
      all_values = started.flat_map { |spec| spec.env.values }
      mixed_in = supplied.values.any? { |value| all_values.include?(value) }
      expect(mixed_in).to be(false), "expected no supplied value with #{label}"
      monolith_env = monolith.first.env
      timekeeping_env = timekeeping.first.env
      # fetch, so a token missing from both apps fails here instead of comparing nil to nil.
      shared_token = monolith_env.fetch(token) == timekeeping_env.fetch(token)
      expect(shared_token).to be(true), "expected one shared token with #{label}"
      signer = OpenSSL::PKey::RSA.new(monolith_env.fetch(private_key))
      verifier = OpenSSL::PKey::RSA.new(timekeeping_env.fetch(public_key))
      signature = signer.sign("SHA256", "timekeeping-demo")
      paired = verifier.verify("SHA256", signature, "timekeeping-demo")
      expect(paired).to be(true), "expected a matching key pair with #{label}"
      # "Timekeeping gets the public key and the token, and never the private key."
      private_key_in_timekeeping = timekeeping.any? { |spec| spec.env.key?(private_key) }
      expect(private_key_in_timekeeping).to be(false), "expected no private key in Timekeeping with #{label}"
    end
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "up never copies a partial caller credential into any app through the toolchain, copied or always_set lists" do
    credential_keys = TimekeepingDemo::Credentials::ENV_KEYS.values
    # "Never add these keys to `TOOLCHAIN_KEYS` or to any `copied` or `always_set` list."
    generic_lists = [TimekeepingDemo::RuntimePlan::TOOLCHAIN_KEYS] +
                    TimekeepingDemo::RuntimePlan::APPLICATIONS.values.flat_map { |settings| settings.values_at(:copied, :always_set) }
    expect(generic_lists.flatten.intersect?(credential_keys)).to be(false)

    supplied = TimekeepingDemo::Credentials.generate
    private_key_name = TimekeepingDemo::Credentials::ENV_KEYS.fetch(:private_key_pem)
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare)
    allow(supervisor).to receive(:run) { |specs, **_kwargs| started.concat(specs) }
    caller_env = ENV.to_h.slice(*TimekeepingDemo::RuntimePlan::TOOLCHAIN_KEYS).merge(
      "DB_USER" => "monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user@127.0.0.1:5432/timekeeping_test",
      private_key_name => supplied.private_key_pem
    )

    Dir.mktmpdir do |state_dir|
      TimekeepingDemo::CLI.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
    end

    expect(started).not_to be_empty
    leaked = started.any? { |spec| spec.env.values.any? { |value| value == supplied.private_key_pem } }
    expect(leaked).to be(false)
    timekeeping_has_private_key = started.select { |spec| spec.app == :timekeeping }.any? { |spec| spec.env.key?(private_key_name) }
    expect(timekeeping_has_private_key).to be(false)
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "run without a supervisor builds one that records groups in tmp/timekeeping-demo/process_groups" do
    root = Rails.root.to_s
    built_with = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    # Stops `up` at prepare, so no process starts and no versions file is written.
    allow(supervisor).to receive(:prepare).and_raise(TimekeepingDemo::Supervisor::ProcessFailed, "stopped by the test")
    allow(TimekeepingDemo::Supervisor).to receive(:new) do |**kwargs|
      built_with << kwargs
      supervisor
    end
    caller_env = {
      "PATH" => ENV.fetch("PATH", ""),
      "DB_USER" => "cli_groups_monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://cli_groups_timekeeping_user@127.0.0.1:5432/timekeeping_cli_groups_test"
    }

    status = nil
    expect { status = described_class.run(["up"], root:, caller_env:) }.to output.to_stderr

    # "`CLI.run` points the default supervisor at tmp/timekeeping-demo/process_groups."
    expect(built_with.size).to eq(1)
    expect(built_with.first[:groups_path]).to eq(File.join(root, "tmp", "timekeeping-demo", "process_groups"))
    expect(status).to eq(described_class::EX_FAILURE)
  end
end

RSpec.describe TimekeepingDemo::CLI do
  # "Hold them as `TimekeepingDemo::Credentials::ENV_KEYS` and make lib/timekeeping_demo/runtime_plan.rb refer to that constant."
  # Renaming the keys in that one constant must rename them in every app's environment.
  it "up hands each app its credential entries under the key names Credentials::ENV_KEYS holds" do
    renamed_keys = { private_key_pem: "DEMO_RENAMED_PRIVATE", public_key_pem: "DEMO_RENAMED_PUBLIC",
                     service_token: "DEMO_RENAMED_TOKEN" }.freeze
    stub_const("TimekeepingDemo::Credentials::ENV_KEYS", renamed_keys)
    supplied = TimekeepingDemo::Credentials.generate
    caller_env = {
      "PATH" => ENV.fetch("PATH", "/usr/bin"),
      "DB_USER" => "monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo_user@127.0.0.1:5432/timekeeping_demo_test",
      renamed_keys[:private_key_pem] => supplied.private_key_pem,
      renamed_keys[:public_key_pem] => supplied.public_key_pem,
      renamed_keys[:service_token] => supplied.service_token
    }
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare)
    allow(supervisor).to receive(:run) { |specs, **| started.concat(specs) }

    Dir.mktmpdir do |state_dir|
      described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
    end

    monolith = started.select { |spec| spec.app == :monolith }
    timekeeping = started.select { |spec| spec.app == :timekeeping }
    expect(monolith).not_to be_empty
    expect(timekeeping).not_to be_empty
    expect(monolith.all? { |spec| spec.env[renamed_keys[:private_key_pem]] == supplied.private_key_pem }).to be(true)
    expect(monolith.all? { |spec| spec.env[renamed_keys[:service_token]] == supplied.service_token }).to be(true)
    expect(timekeeping.all? { |spec| spec.env[renamed_keys[:public_key_pem]] == supplied.public_key_pem }).to be(true)
    expect(timekeeping.all? { |spec| spec.env[renamed_keys[:service_token]] == supplied.service_token }).to be(true)
    expect(timekeeping.none? { |spec| spec.env.key?(renamed_keys[:private_key_pem]) }).to be(true)
    old_names = %w[TIMEKEEPING_TOKEN_PRIVATE_KEY TIMEKEEPING_TOKEN_PUBLIC_KEY TIMEKEEPING_SERVICE_TOKEN]
    expect(started.none? { |spec| old_names.any? { |name| spec.env.key?(name) } }).to be(true)
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "default regression runner hands argv to system as separate arguments and never as a shell string" do
    root = Dir.mktmpdir("regression root with space")
    calls = []
    allow(described_class).to receive(:system) do |*args, **opts|
      calls << [args, opts]
      false
    end

    runner = described_class.default_regression_runner(root:, caller_env: { "KEEP_ME" => "1" })
    hostile = "spec/x_spec.rb; touch #{root}/pwned"
    result = runner.call(env: { "TIMEKEEPING_OWNER_STATE" => "legacy" }, argv: [hostile, "--tag", "~switches_owner"])

    # "The default runner, built by `CLI.run` from `root:` and `caller_env:`, uses `system(env, "bundle", "exec", "rspec", *argv, chdir: root)` with an argv array, never a shell string."
    expect(calls.size).to eq(1)
    args, opts = calls.first
    expect(args).to eq([{ "KEEP_ME" => "1", "TIMEKEEPING_OWNER_STATE" => "legacy" },
                        "bundle", "exec", "rspec", hostile, "--tag", "~switches_owner"])
    expect(opts).to eq(chdir: root)
    expect(result).to be(false)
    expect(File).not_to exist(File.join(root, "pwned"))
  ensure
    FileUtils.rm_rf(root) if root
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "regression children never inherit the caller's owner state or queue ledger path" do
    envs = []
    allow(described_class).to receive(:system) do |env, *_args, **_opts|
      envs << env
      true
    end
    supervisor = double("timekeeping demo supervisor")
    parent_ledger = "/parent/queue_ledger.json"
    caller_env = { "TIMEKEEPING_OWNER_STATE" => "rollback", "TIMEKEEPING_QUEUE_LEDGER_PATH" => parent_ledger }

    Dir.mktmpdir do |dir|
      state_dir = File.join(dir, "state")
      expect do
        described_class.run(["regression"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
      end.to output.to_stdout

      expect(Dir).not_to exist(state_dir)
    end

    # "Each child env sets `TIMEKEEPING_OWNER_STATE` to its state (overriding any caller value), `TIMEKEEPING_REGRESSION=1`, `TIMEKEEPING_LIVE=1`, and its own `TIMEKEEPING_QUEUE_LEDGER_PATH` in a fresh temp directory (a child rspec that inherits the parent's ledger path deletes the parent's ledger at suite start)."
    state_envs = envs.select { |env| env["TIMEKEEPING_OWNER_STATE"] }
    expect(state_envs.pluck("TIMEKEEPING_OWNER_STATE")).to eq(%w[legacy timekeeping rollback])
    ledgers = envs.pluck("TIMEKEEPING_QUEUE_LEDGER_PATH")
    expect(ledgers).to all(be_a(String))
    expect(ledgers).not_to include(parent_ledger)
    expect(ledgers.uniq.size).to eq(envs.size)

    # The report pass runs with "no owner state": a nil value makes system remove the inherited key.
    report_envs = envs - state_envs
    expect(report_envs.size).to eq(1)
    expect(report_envs.first).to have_key("TIMEKEEPING_OWNER_STATE")
    expect(report_envs.first["TIMEKEEPING_OWNER_STATE"]).to be_nil
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "an unknown verb or a regression verb with extra arguments returns 64 and starts neither the supervisor nor the runner" do
    supervisor = double("timekeeping demo supervisor")
    regression_runner = double("regression runner")

    [["nope"], ["regression", "; rm -rf /"]].each do |argv|
      Dir.mktmpdir do |dir|
        state_dir = File.join(dir, "state")
        status = nil
        # "`CLI.run(["nope"])` returns 64 and calls neither the supervisor nor the runner"
        expect do
          status = described_class.run(argv, root: Rails.root.to_s, supervisor:, state_dir:, regression_runner:)
        end.to output(/regression/).to_stderr

        expect(status).to eq(described_class::EX_USAGE)
        expect(status).to eq(64)
        expect(Dir).not_to exist(state_dir)
      end
    end
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "regression calls the runner once per state, in order, with the full 12.1 list and never builds the supervisor" do
    expected_specs = %w[
      spec/models/timesheet_entry_spec.rb
      spec/policies/timesheet_entry_policy_spec.rb
      spec/requests/api/v1/timesheet_entries/bulk_actions/update_spec.rb
      spec/requests/api/v1/timesheet_entries/bulk_actions/destroy_spec.rb
      spec/requests/api/v1/timesheet_entry/index_spec.rb
      spec/requests/api/v1/cli/timesheet_entries/create_spec.rb
      spec/requests/api/v1/cli/timesheet_entries/update_spec.rb
      spec/requests/api/v1/cli/timesheet_entries/destroy_spec.rb
      spec/mcp/tools/write_tools_spec.rb
      spec/mcp/idempotency_store_spec.rb
      spec/requests/api/v1/agent/timesheet_entries/create_spec.rb
      spec/requests/api/v1/invoices/create_spec.rb
      spec/models/invoice_spec.rb
      spec/models/invoice_line_item_spec.rb
      spec/requests/api/v1/invoices/send_invoice_spec.rb
      spec/system/invoices/send_invoice_spec.rb
      spec/services/imports/harvest_time_entries_importer_spec.rb
      spec/services/reports/time_entries/
      spec/services/analytics/team_productivity_analytics_spec.rb
      spec/services/metrics/data_builder_spec.rb
      spec/characterization/invoice_entry_locking_spec.rb
      spec/characterization/timesheet_entry_rules_spec.rb
      spec/characterization/entry_lookups_and_pdf_totals_spec.rb
    ]
    flags = ["--tag", "~switches_owner"]
    calls = []
    runner = lambda do |env:, argv:|
      calls << { env:, argv: }
      true
    end
    supervisor = double("timekeeping demo supervisor")

    Dir.mktmpdir do |parent|
      state_dir = File.join(parent, "state")
      status = nil
      expect do
        status = described_class.run(["regression"], root: Rails.root.to_s, supervisor:, state_dir:,
                                                     caller_env: {}, regression_runner: runner)
      end.to output.to_stdout

      expect(status).to eq(0)
      # "`CLI.run([\"regression\"])` never calls the supervisor."
      expect(File).not_to exist(state_dir)
    end

    state_calls = calls.select { |call| call[:argv].include?("~switches_owner") }
    # "`CLI.run([\"regression\"])` calls the runner three times with each state (legacy, timekeeping, rollback) and the full list, including the three characterization specs"
    expect(state_calls.map { |call| call[:env]["TIMEKEEPING_OWNER_STATE"] }).to eq(%w[legacy timekeeping rollback])
    state_calls.each do |call|
      expect(call[:argv] - flags).to contain_exactly(*expected_specs)
      expect(call[:argv]).to include(*flags)
      expect(call[:argv][call[:argv].index("--tag") + 1]).to eq("~switches_owner")
    end
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "USAGE names both the up and the regression commands" do
    # "USAGE names up and regression, and `CLI.run([\"nope\"])` still returns `EX_USAGE` and starts nothing"
    expect(described_class::USAGE).to match(/\bup\b/)
    expect(described_class::USAGE).to match(/\bregression\b/)
  end
end

RSpec.describe TimekeepingDemo::CLI do
  it "the default regression runner calls system with an argv array, the child state over the caller's, chdir root, and passes nil through" do
    caller_env = { "TIMEKEEPING_OWNER_STATE" => "rollback", "KEEP_ME" => "x" }
    # "The default runner, built by `CLI.run` from `root:` and `caller_env:`, uses `system(env, \"bundle\", \"exec\", \"rspec\", *argv, chdir: root)` with an argv array, never a shell string."
    expect(described_class).to receive(:system)
      .with({ "TIMEKEEPING_OWNER_STATE" => "legacy", "KEEP_ME" => "x" },
            "bundle", "exec", "rspec", "spec/a b_spec.rb", "--tag", "~switches_owner", chdir: "/srv/app")
      .and_return(nil)

    runner = described_class.default_regression_runner(root: "/srv/app", caller_env:)
    result = runner.call(env: { "TIMEKEEPING_OWNER_STATE" => "legacy" },
                         argv: ["spec/a b_spec.rb", "--tag", "~switches_owner"])

    # "Only `true` counts as a pass; `false` and `nil` (spawn failure, killed by a signal) fail."
    expect(result).to be_nil
    expect(caller_env).to eq("TIMEKEEPING_OWNER_STATE" => "rollback", "KEEP_ME" => "x")
  end
end

RSpec.describe TimekeepingDemo::CLI do
  # "Each child env sets `TIMEKEEPING_OWNER_STATE` to its state (overriding any caller value), `TIMEKEEPING_REGRESSION=1`,
  # `TIMEKEEPING_LIVE=1`, and its own `TIMEKEEPING_QUEUE_LEDGER_PATH` in a fresh temp directory (a child rspec that
  # inherits the parent's ledger path deletes the parent's ledger at suite start)."
  it "regression overrides a caller TIMEKEEPING_OWNER_STATE per state and sends no owner state to the report pass" do
    calls = []
    runner = ->(env:, argv:) { calls << [env, argv] and true }

    Dir.mktmpdir do |state_dir|
      caller_env = { "TIMEKEEPING_OWNER_STATE" => "rollback", "TIMEKEEPING_QUEUE_LEDGER_PATH" => "/caller/ledger.json" }
      expect do
        described_class.run(["regression"], root: Rails.root.to_s, supervisor: double("timekeeping demo supervisor"),
                                            state_dir:, caller_env:, regression_runner: runner)
      end.to output.to_stdout

      state_calls = calls.reject { |_env, argv| argv.include?("switches_owner") }
      report_calls = calls.select { |_env, argv| argv.include?("switches_owner") }
      expect(state_calls.map { |env, _argv| env["TIMEKEEPING_OWNER_STATE"] }).to eq(%w[legacy timekeeping rollback])
      expect(report_calls.size).to eq(1)
      # The child env is merged over the caller's, so the report pass must clear the key, not omit it or blank it.
      report_env = caller_env.merge(report_calls.first.first)
      expect(report_env["TIMEKEEPING_OWNER_STATE"]).to be_nil
      expect(calls.map { |env, _argv| env["TIMEKEEPING_QUEUE_LEDGER_PATH"] }).not_to include("/caller/ledger.json")
      expect(Dir.children(state_dir)).to be_empty
    end
  end
end

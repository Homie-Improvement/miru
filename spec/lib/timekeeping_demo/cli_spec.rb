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
  let(:caller_credentials_supervisor_class) do
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

  it "up with caller credentials gives each app exactly its permitted values and writes none to versions.json or output" do
    supplied = TimekeepingDemo::Credentials.generate
    keys = TimekeepingDemo::Credentials::ENV_KEYS
    private_key = keys.fetch(:private_key_pem)
    public_key = keys.fetch(:public_key_pem)
    token = keys.fetch(:service_token)
    caller_env = ENV.to_h.slice("PATH", "HOME", "GEM_HOME", "GEM_PATH").merge(
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo_role@127.0.0.1/timekeeping_demo",
      "DB_USER" => "monolith_demo_role"
    ).merge(supplied.to_env)
    supervisor = caller_credentials_supervisor_class.new
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

      monolith_envs = supervisor.specs.filter_map { |spec| spec.env if spec.app == :monolith }
      timekeeping_envs = supervisor.specs.filter_map { |spec| spec.env if spec.app == :timekeeping }
      expect(monolith_envs).not_to be_empty
      expect(timekeeping_envs).not_to be_empty

      # "`CLI.up` with all three keys in caller_env gives each app exactly its permitted values, byte for byte. The Timekeeping env holds no private key. Comparisons report booleans, never the values."
      monolith_envs.each do |env|
        expect(env[private_key] == supplied.private_key_pem).to be(true)
        expect(env[token] == supplied.service_token).to be(true)
        expect(env.key?(public_key)).to be(false)
      end
      timekeeping_envs.each do |env|
        expect(env[public_key] == supplied.public_key_pem).to be(true)
        expect(env[token] == supplied.service_token).to be(true)
        # "Timekeeping gets the public key and the token, and never the private key."
        expect(env.key?(private_key)).to be(false)
        expect(env.values.any? { |value| value == supplied.private_key_pem }).to be(false)
      end

      # "versions.json, the captured stdout and stderr, and the runtime output hold none of the values."
      written = [File.read(File.join(state_dir, "versions.json")), captured_out.string, captured_err.string].join
      supplied.to_env.each_value { |value| expect(written.include?(value)).to be(false) }
    end
  end

  it "up with a partial or blank caller set starts the apps with one fresh matching set and no supplied value" do
    keys = TimekeepingDemo::Credentials::ENV_KEYS
    private_key = keys.fetch(:private_key_pem)
    public_key = keys.fetch(:public_key_pem)
    token = keys.fetch(:service_token)
    supplied = TimekeepingDemo::Credentials.generate
    base_env = ENV.to_h.slice("PATH", "HOME", "GEM_HOME", "GEM_PATH").merge(
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo_role@127.0.0.1/timekeeping_demo",
      "DB_USER" => "monolith_demo_role"
    )
    partial_sets = keys.values.flat_map do |key|
      [supplied.to_env.except(key), supplied.to_env.merge(key => " ")]
    end

    partial_sets.each do |partial|
      supervisor = caller_credentials_supervisor_class.new
      Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
        expect(described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:,
                                           caller_env: base_env.merge(partial))).to eq(0)
      end

      monolith = supervisor.specs.find { |spec| spec.app == :monolith }.env
      timekeeping = supervisor.specs.find { |spec| spec.app == :timekeeping }.env

      # "A partial or blank set therefore gets a whole fresh set and is never mixed with supplied values."
      supplied.to_env.each_value do |value|
        expect((monolith.values + timekeeping.values).include?(value)).to be(false)
      end
      expect(monolith[token] == timekeeping[token]).to be(true)
      signer = OpenSSL::PKey::RSA.new(monolith.fetch(private_key))
      verifier = OpenSSL::PKey::RSA.new(timekeeping.fetch(public_key))
      signature = signer.sign("SHA256", "timekeeping-demo")
      expect(verifier.verify("SHA256", signature, "timekeeping-demo")).to be(true)
      # "Timekeeping gets the public key and the token, and never the private key."
      expect(timekeeping.key?(private_key)).to be(false)
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
  it "up with all three caller credentials starts the apps with them and writes none to versions.json or the output" do
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare) { |*_args, **_kwargs| true }
    allow(supervisor).to receive(:run) do |specs, *_rest, **_kwargs|
      started.concat(specs)
      0
    end
    supplied = TimekeepingDemo::Credentials.generate
    caller_env = {
      "PATH" => ENV.fetch("PATH"),
      "DB_USER" => "monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user@127.0.0.1:5432/timekeeping_test"
    }.merge(supplied.to_env)
    secrets = [supplied.private_key_pem, supplied.public_key_pem, supplied.service_token]
    keys = TimekeepingDemo::Credentials::ENV_KEYS

    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      captured_out = StringIO.new
      captured_err = StringIO.new
      original_out = $stdout
      original_err = $stderr
      begin
        $stdout = captured_out
        $stderr = captured_err
        described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
      ensure
        $stdout = original_out
        $stderr = original_err
      end

      monolith = started.find { |spec| spec.app == :monolith }.env
      timekeeping = started.find { |spec| spec.app == :timekeeping }.env
      # "`CLI.up` uses credentials from `caller_env` when all are present, and otherwise generates them as before."
      expect(monolith[keys.fetch(:private_key_pem)] == supplied.private_key_pem).to be(true)
      expect(monolith[keys.fetch(:service_token)] == supplied.service_token).to be(true)
      expect(timekeeping[keys.fetch(:public_key_pem)] == supplied.public_key_pem).to be(true)
      expect(timekeeping[keys.fetch(:service_token)] == supplied.service_token).to be(true)
      # "Timekeeping gets the public key and the token, and never the private key."
      expect(timekeeping.key?(keys.fetch(:private_key_pem))).to be(false)

      # "Never log, print or write them to versions.json."
      versions_text = File.read(File.join(state_dir, "versions.json"))
      written = [versions_text, captured_out.string, captured_err.string]
      leaked = written.any? { |text| secrets.any? { |secret| text.include?(secret) } }
      expect(leaked).to be(false)
    end
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

RSpec.describe TimekeepingDemo::CLI, "up with caller credentials" do
  it "up with all three credential keys in caller_env gives each app exactly its permitted values and writes none of them out" do
    supplied = TimekeepingDemo::Credentials.generate
    caller_env = {
      "PATH" => ENV.fetch("PATH"),
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_caller_role@127.0.0.1/timekeeping_caller_test",
      "DB_USER" => "monolith_caller_role",
      "TIMEKEEPING_TOKEN_PRIVATE_KEY" => supplied.private_key_pem,
      "TIMEKEEPING_TOKEN_PUBLIC_KEY" => supplied.public_key_pem,
      "TIMEKEEPING_SERVICE_TOKEN" => supplied.service_token
    }
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare)
    allow(supervisor).to receive(:run) { |specs, **| started.concat(specs) }

    Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
      captured_out = StringIO.new
      captured_err = StringIO.new
      original_out = $stdout
      original_err = $stderr
      begin
        $stdout = captured_out
        $stderr = captured_err
        status = described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
        expect(status).to eq(0)
      ensure
        $stdout = original_out
        $stderr = original_err
      end

      monolith = started.select { |spec| spec.app == :monolith }
      timekeeping = started.select { |spec| spec.app == :timekeeping }
      expect(monolith).not_to be_empty
      expect(timekeeping).not_to be_empty

      # "`CLI.up` with all three keys in caller_env gives each app exactly its permitted values, byte for byte.
      # The Timekeeping env holds no private key. Comparisons report booleans, never the values."
      monolith.each do |spec|
        expect(spec.env["TIMEKEEPING_TOKEN_PRIVATE_KEY"] == supplied.private_key_pem).to be(true)
        expect(spec.env["TIMEKEEPING_SERVICE_TOKEN"] == supplied.service_token).to be(true)
        expect(spec.env.key?("TIMEKEEPING_TOKEN_PUBLIC_KEY")).to be(false)
      end
      timekeeping.each do |spec|
        expect(spec.env["TIMEKEEPING_TOKEN_PUBLIC_KEY"] == supplied.public_key_pem).to be(true)
        expect(spec.env["TIMEKEEPING_SERVICE_TOKEN"] == supplied.service_token).to be(true)
        expect(spec.env.key?("TIMEKEEPING_TOKEN_PRIVATE_KEY")).to be(false)
        expect(spec.env.values.any? { |value| value == supplied.private_key_pem }).to be(false)
      end

      # "versions.json, the captured stdout and stderr, and the runtime output hold none of the values."
      versions_text = File.read(File.join(state_dir, "versions.json"))
      secrets = [supplied.private_key_pem, supplied.public_key_pem, supplied.service_token]
      [versions_text, captured_out.string, captured_err.string].each do |text|
        expect(secrets.any? { |secret| text.include?(secret) }).to be(false)
      end
    end
  end
end

RSpec.describe TimekeepingDemo::CLI, "up with an incomplete caller credential set" do
  it "up with a partial or blank credential set in caller_env starts the apps with a fresh matching set and none of the supplied values" do
    supplied = TimekeepingDemo::Credentials.generate
    complete = {
      "TIMEKEEPING_TOKEN_PRIVATE_KEY" => supplied.private_key_pem,
      "TIMEKEEPING_TOKEN_PUBLIC_KEY" => supplied.public_key_pem,
      "TIMEKEEPING_SERVICE_TOKEN" => supplied.service_token
    }
    base_env = {
      "PATH" => ENV.fetch("PATH"),
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_caller_role@127.0.0.1/timekeeping_caller_test",
      "DB_USER" => "monolith_caller_role"
    }
    variants = complete.keys.flat_map do |key|
      [complete.except(key), complete.merge(key => ""), complete.merge(key => "  ")]
    end

    variants.each do |credential_env|
      started = []
      supervisor = instance_double(TimekeepingDemo::Supervisor)
      allow(supervisor).to receive(:prepare)
      allow(supervisor).to receive(:run) { |specs, **| started.concat(specs) }

      Dir.mktmpdir("timekeeping-demo-state") do |state_dir|
        status = described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:,
                                             caller_env: base_env.merge(credential_env))
        expect(status).to eq(0)
      end

      # "`CLI.up` uses `Credentials.from_env(caller_env) || Credentials.generate`. A partial or blank set therefore
      # gets a whole fresh set and is never mixed with supplied values."
      monolith = started.find { |spec| spec.app == :monolith }
      timekeeping = started.find { |spec| spec.app == :timekeeping }
      private_pem = monolith.env.fetch("TIMEKEEPING_TOKEN_PRIVATE_KEY")
      public_pem = timekeeping.env.fetch("TIMEKEEPING_TOKEN_PUBLIC_KEY")
      private_key = OpenSSL::PKey::RSA.new(private_pem)
      public_key = OpenSSL::PKey::RSA.new(public_pem)
      signature = private_key.sign("SHA256", "timekeeping harness check")
      expect(public_key.verify("SHA256", signature, "timekeeping harness check")).to be(true)
      expect(monolith.env["TIMEKEEPING_SERVICE_TOKEN"] == timekeeping.env["TIMEKEEPING_SERVICE_TOKEN"]).to be(true)

      supplied_values = complete.values
      all_values = started.flat_map { |spec| spec.env.values }
      expect(all_values.any? { |value| supplied_values.include?(value) }).to be(false)
      # "Timekeeping gets the public key and the token, and never the private key."
      expect(started.select { |spec| spec.app == :timekeeping }.any? { |spec| spec.env.key?("TIMEKEEPING_TOKEN_PRIVATE_KEY") }).to be(false)
    end
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
  it "up with a partial credential set starts both apps on one fresh matching set and never mixes in a supplied value" do
    keys = TimekeepingDemo::Credentials::ENV_KEYS
    supplied = TimekeepingDemo::Credentials.generate.to_env
    supplied.delete(keys.fetch(:public_key_pem))
    started = []
    supervisor = instance_double(TimekeepingDemo::Supervisor)
    allow(supervisor).to receive(:prepare)
    allow(supervisor).to receive(:run) { |specs, **| started.concat(specs) }
    caller_env = ENV.to_h.except(*keys.values).merge(supplied).merge(
      "DB_USER" => "monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user@127.0.0.1:5432/timekeeping_test"
    )

    Dir.mktmpdir do |state_dir|
      described_class.run(["up"], root: Rails.root.to_s, supervisor:, state_dir:, caller_env:)
    end

    monolith = started.find { |spec| spec.app == :monolith }.env
    timekeeping = started.find { |spec| spec.app == :timekeeping }.env
    # "A partial or blank set therefore gets a whole fresh set and is never mixed with supplied values."
    all_values = started.flat_map { |spec| spec.env.values }
    expect(supplied.values.any? { |value| all_values.include?(value) }).to be(false)
    private_key = OpenSSL::PKey::RSA.new(monolith.fetch(keys.fetch(:private_key_pem)))
    public_key = OpenSSL::PKey::RSA.new(timekeeping.fetch(keys.fetch(:public_key_pem)))
    signature = private_key.sign("SHA256", "pairing check")
    expect(public_key.verify("SHA256", signature, "pairing check")).to be(true)
    expect(monolith.fetch(keys.fetch(:service_token)) == timekeeping.fetch(keys.fetch(:service_token))).to be(true)
    # "Timekeeping gets the public key and the token, and never the private key."
    expect(timekeeping.key?(keys.fetch(:private_key_pem))).to be(false)
  end
end

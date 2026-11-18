# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingDemo::RuntimePlan, "demo Puma config and blank monolith database keys" do
  let(:demo_runtime_specs) do
    described_class.build(
      root: Rails.root.to_s,
      procfile: Rails.root.join("Procfile.timekeeping").read,
      caller_env: {
        "PATH" => ENV.fetch("PATH", "/usr/bin"),
        "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo_user@127.0.0.1:5432/timekeeping_demo"
      },
      credentials: TimekeepingDemo::Credentials.generate,
      ports: { monolith: 3000, timekeeping: 3100 },
      login_user: "demo_login_user"
    )
  end

  # "The default worker is not started, because the seeded data already holds queued integration jobs and the default worker would run them."
  it "serves the monolith web app from the demo Puma config, which never starts a Solid Queue supervisor" do
    web = demo_runtime_specs.find { |spec| spec.name == "monolith_web" }

    expect(web.argv).to include("config/puma_timekeeping_demo.rb")
    expect(web.argv).to include("tcp://127.0.0.1:3000")
    expect(Rails.root.join("config/puma_timekeeping_demo.rb").read).not_to match(/^\s*plugin\s+:solid_queue/)
  end

  it "sets the monolith database keys to empty values when the caller omits them, so a local .env cannot fill them" do
    demo_runtime_specs.select { |spec| spec.app == :monolith }.each do |spec|
      expect(spec.env.fetch_values("DATABASE_URL", "DB_USER", "DB_PASS", "TIMEKEEPING_DATABASE_URL"))
        .to eq(["", "", "", ""])
    end
  end

  it "refuses when neither application names a database user, because both would connect as the login user" do
    expect do
      described_class.build(
        root: Rails.root.to_s,
        procfile: Rails.root.join("Procfile.timekeeping").read,
        caller_env: { "TIMEKEEPING_DATABASE_URL" => "postgres://127.0.0.1:5432/timekeeping_demo" },
        credentials: TimekeepingDemo::Credentials.generate,
        ports: { monolith: 3000, timekeeping: 3100 },
        login_user: "demo_login_user"
      )
    end.to raise_error(TimekeepingDemo::ConfigurationError, /own user/)
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  # "The runtime therefore starts the monolith web app, the Timekeeping web app, the Timekeeping relay worker,
  # the monolith relay worker and the invoice-operation worker, and nothing else."
  it "builds exactly the two web apps, both relay workers and the invoice-operation worker from Procfile.timekeeping" do
    root = Rails.root.to_s
    caller_env = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => Dir.home,
      "DB_USER" => "monolith_demo",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo@127.0.0.1/timekeeping_demo"
    }

    specs = described_class.build(
      root:,
      procfile: File.read(Rails.root.join("Procfile.timekeeping")),
      caller_env:,
      credentials: TimekeepingDemo::Credentials.generate,
      ports: { monolith: 3000, timekeeping: 3100 }
    )

    expect(specs.map(&:name)).to contain_exactly(
      "monolith_web", "monolith_relay", "monolith_invoice_operations", "timekeeping_web", "timekeeping_relay"
    )
    expect(specs.map(&:name).uniq.size).to eq(5)
    # "The default worker is not started, because the seeded data already holds queued integration jobs and the default worker would run them."
    specs.each do |spec|
      expect(spec.argv).not_to include("config/solid_queue.yml")
      expect(spec.argv.join(" ")).not_to match(/\bqueues?\b.*\bdefault\b/)
    end
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  # "In the local demo each application reads these keys from its own process environment, and the two
  # applications share no database credential."
  it "gives each application only its own database credential and keeps the private key in the monolith" do
    credentials = TimekeepingDemo::Credentials.generate
    caller_env = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => Dir.home,
      "DATABASE_URL" => "postgres://monolith_demo@127.0.0.1/miru_web_development",
      "DB_USER" => "monolith_demo",
      "DB_PASS" => "monolith-pass",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo@127.0.0.1/timekeeping_demo",
      "TIMEKEEPING_TEST_HOOKS" => "1",
      "UNRELATED_SECRET_FOR_DEMO_SPEC" => "must-not-leak"
    }

    specs = described_class.build(
      root: Rails.root.to_s,
      procfile: File.read(Rails.root.join("Procfile.timekeeping")),
      caller_env:,
      credentials:,
      ports: { monolith: 3000, timekeeping: 3100 }
    )
    monolith, timekeeping = specs.partition { |spec| spec.app == :monolith }

    expect(monolith.map(&:name)).to contain_exactly("monolith_web", "monolith_relay", "monolith_invoice_operations")
    expect(timekeeping.map(&:name)).to contain_exactly("timekeeping_web", "timekeeping_relay")

    timekeeping.each do |spec|
      expect(spec.env["TIMEKEEPING_DATABASE_URL"]).to eq(caller_env["TIMEKEEPING_DATABASE_URL"])
      expect(spec.env).not_to include("DATABASE_URL", "DB_USER", "DB_PASS", "TIMEKEEPING_TOKEN_PRIVATE_KEY")
      expect(spec.env["TIMEKEEPING_TOKEN_PUBLIC_KEY"]).to eq(credentials.public_key_pem)
      expect(spec.env["TIMEKEEPING_SERVICE_TOKEN"]).to eq(credentials.service_token)
    end

    monolith.each do |spec|
      expect(spec.env["DATABASE_URL"]).to eq(caller_env["DATABASE_URL"])
      expect(spec.env["TIMEKEEPING_DATABASE_URL"].to_s).to be_empty
      expect(spec.env["TIMEKEEPING_TOKEN_PRIVATE_KEY"]).to eq(credentials.private_key_pem)
      expect(spec.env["TIMEKEEPING_SERVICE_TOKEN"]).to eq(credentials.service_token)
    end

    specs.each do |spec|
      expect(spec.env).not_to include("TIMEKEEPING_TEST_HOOKS", "UNRELATED_SECRET_FOR_DEMO_SPEC")
    end
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  # "In the local demo each application reads these keys from its own process environment, and the two
  # applications share no database credential."
  it "refuses to build when both applications would connect as the same database user" do
    caller_env = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => Dir.home,
      "DB_USER" => "root",
      "TIMEKEEPING_DATABASE_URL" => "postgres://root@127.0.0.1/timekeeping_demo"
    }

    expect do
      described_class.build(
        root: Rails.root.to_s,
        procfile: File.read(Rails.root.join("Procfile.timekeeping")),
        caller_env:,
        credentials: TimekeepingDemo::Credentials.generate,
        ports: { monolith: 3000, timekeeping: 3100 }
      )
    end.to raise_error(TimekeepingDemo::ConfigurationError)
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "refuses to build without a Timekeeping database URL, naming the key" do
    caller_env = { "PATH" => ENV.fetch("PATH"), "HOME" => Dir.home, "DB_USER" => "monolith_demo" }

    expect do
      described_class.build(
        root: Rails.root.to_s,
        procfile: File.read(Rails.root.join("Procfile.timekeeping")),
        caller_env:,
        credentials: TimekeepingDemo::Credentials.generate,
        ports: { monolith: 3000, timekeeping: 3100 }
      )
    end.to raise_error(TimekeepingDemo::ConfigurationError, /TIMEKEEPING_DATABASE_URL/)
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "runs Timekeeping processes from an absolute timekeeping directory with an absolute Gemfile and binds loopback only" do
    root = Rails.root.to_s
    specs = described_class.build(
      root:,
      procfile: File.read(Rails.root.join("Procfile.timekeeping")),
      caller_env: {
        "PATH" => ENV.fetch("PATH"),
        "HOME" => Dir.home,
        "DB_USER" => "monolith_demo",
        "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_demo@127.0.0.1/timekeeping_demo"
      },
      credentials: TimekeepingDemo::Credentials.generate,
      ports: { monolith: 3000, timekeeping: 3100 }
    )

    specs.each do |spec|
      expect(Pathname.new(spec.chdir)).to be_absolute
      gemfile = spec.env.fetch("BUNDLE_GEMFILE")
      expect(Pathname.new(gemfile)).to be_absolute
      expect(File).to exist(gemfile)
      expect(spec.argv.join(" ")).not_to include("0.0.0.0")
    end

    specs.select { |spec| spec.app == :timekeeping }.each do |spec|
      expect(spec.chdir).to eq(File.join(root, "timekeeping"))
      expect(spec.env.fetch("BUNDLE_GEMFILE")).to eq(File.join(root, "timekeeping", "Gemfile"))
    end

    monolith_urls = specs.find { |spec| spec.name == "monolith_relay" }.env
    expect(monolith_urls.fetch("TIMEKEEPING_BASE_URL")).to eq("http://127.0.0.1:3100")
    timekeeping_env = specs.find { |spec| spec.name == "timekeeping_relay" }.env
    expect(timekeeping_env.fetch("MONOLITH_SNAPSHOT_URL")).to start_with("http://127.0.0.1:3000")
    expect(timekeeping_env.fetch("MONOLITH_REFERENCE_URL")).to start_with("http://127.0.0.1:3000")
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "keeps a caller environment holding both credentials and test hooks from crossing between the applications" do
    procfile = Rails.root.join("Procfile.timekeeping").read
    credentials = TimekeepingDemo::Credentials.generate
    caller_env = {
      "DATABASE_URL" => "postgres://monolith_user:monolith_pw@127.0.0.1:5432/miru_demo",
      "DB_USER" => "monolith_user",
      "DB_PASS" => "monolith_pw",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user:tk_pw@127.0.0.1:5432/timekeeping_demo",
      "TIMEKEEPING_TEST_HOOKS" => "1",
      "TIMEKEEPING_TOKEN_PRIVATE_KEY" => "caller-supplied-private-key",
      "SOME_UNRELATED_SECRET" => "must-not-leak"
    }

    specs = described_class.build(root: Rails.root.to_s, procfile:, caller_env:, credentials:,
                                  ports: { monolith: 3000, timekeeping: 3100 })
    timekeeping_specs = specs.select { |spec| spec.app == :timekeeping }
    monolith_specs = specs.select { |spec| spec.app == :monolith }
    expect(timekeeping_specs.map(&:name)).to contain_exactly("timekeeping_web", "timekeeping_relay")
    expect(monolith_specs.map(&:name)).to contain_exactly("monolith_web", "monolith_relay", "monolith_invoice_operations")

    # "In the local demo each application reads these keys from its own process environment, and the two applications share no database credential."
    timekeeping_specs.each do |spec|
      expect(spec.env.keys).not_to include("DATABASE_URL", "DB_USER", "DB_PASS", "TIMEKEEPING_TOKEN_PRIVATE_KEY")
      expect(spec.env.values).not_to include("monolith_pw", "caller-supplied-private-key", credentials.private_key_pem)
      expect(spec.env).not_to have_key("TIMEKEEPING_TEST_HOOKS")
      expect(spec.env).not_to have_key("SOME_UNRELATED_SECRET")
    end

    monolith_specs.each do |spec|
      # Set but empty, so a local .env loaded by dotenv cannot fill the Timekeeping credential in.
      expect(spec.env.fetch("TIMEKEEPING_DATABASE_URL")).to eq("")
      expect(spec.env.values).not_to include("tk_pw")
      expect(spec.env).not_to have_key("TIMEKEEPING_TEST_HOOKS")
      expect(spec.env).not_to have_key("SOME_UNRELATED_SECRET")
      # "`bin/timekeeping-demo` generates an ephemeral key pair and a random service token at runtime."
      expect(spec.env.fetch("TIMEKEEPING_TOKEN_PRIVATE_KEY")).to eq(credentials.private_key_pem)
    end
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "refuses a process table line that belongs to neither application or uses an unknown placeholder" do
    credentials = TimekeepingDemo::Credentials.generate
    caller_env = {
      "DB_USER" => "monolith_user",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user@127.0.0.1:5432/timekeeping_demo"
    }
    base = Rails.root.join("Procfile.timekeeping").read

    # "The runtime therefore starts the monolith web app, the Timekeeping web app, the Timekeeping relay worker, the monolith relay worker and the invoice-operation worker, and nothing else."
    extra_worker = "#{base.chomp}\ndefault_worker: bundle exec rake solid_queue:start\n"
    unknown_placeholder = "#{base.chomp}\nmonolith_extra: bin/rails server -b 127.0.0.1 -p ${OTHER_PORT}\n"

    [extra_worker, unknown_placeholder].each do |procfile|
      expect do
        described_class.build(root: Rails.root.to_s, procfile:, caller_env:, credentials:,
                              ports: { monolith: 3000, timekeeping: 3100 })
      end.to raise_error(TimekeepingDemo::ConfigurationError)
    end
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "refuses to build when TIMEKEEPING_DATABASE_URL is missing instead of handing Timekeeping another credential" do
    procfile = Rails.root.join("Procfile.timekeeping").read
    credentials = TimekeepingDemo::Credentials.generate
    caller_env = { "DATABASE_URL" => "postgres://monolith_user:pw@127.0.0.1:5432/miru_demo" }

    # "In the local demo each application reads these keys from its own process environment, and the two applications share no database credential."
    expect do
      described_class.build(root: Rails.root.to_s, procfile:, caller_env:, credentials:,
                            ports: { monolith: 3000, timekeeping: 3100 })
    end.to raise_error(TimekeepingDemo::ConfigurationError, /TIMEKEEPING_DATABASE_URL/)
  end
end

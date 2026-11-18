# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "gives each application only its own database credential and keeps the private key in the monolith" do
    credentials = TimekeepingDemo::Credentials.generate
    caller_env = {
      "PATH" => ENV.fetch("PATH", "/usr/bin"),
      "DATABASE_URL" => "postgres://monolith_user:monolith_secret@127.0.0.1:5432/miru_web_development",
      "DB_USER" => "monolith_user",
      "DB_PASS" => "monolith_secret",
      "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user:timekeeping_secret@127.0.0.1:5432/timekeeping_development"
    }
    specs = described_class.build(
      root: Rails.root.to_s,
      procfile: File.read(Rails.root.join("Procfile.timekeeping")),
      caller_env:,
      credentials:,
      ports: { monolith: 3000, timekeeping: 3100 }
    )
    timekeeping_specs = specs.select { |spec| spec.app == :timekeeping }
    monolith_specs = specs.select { |spec| spec.app == :monolith }
    expect(timekeeping_specs).not_to be_empty
    expect(monolith_specs).not_to be_empty

    # "In the local demo each application reads these keys from its own process environment, and the two applications share no database credential."
    timekeeping_specs.each do |spec|
      expect(spec.env["TIMEKEEPING_DATABASE_URL"]).to eq(caller_env["TIMEKEEPING_DATABASE_URL"])
      expect(spec.env).not_to include("DATABASE_URL", "DB_USER", "DB_PASS", "TIMEKEEPING_TOKEN_PRIVATE_KEY")
      expect(spec.env.values.join("\n")).not_to include("monolith_secret")
      expect(spec.env.values.join("\n")).not_to include(credentials.private_key_pem)
      expect(spec.env["TIMEKEEPING_TOKEN_PUBLIC_KEY"]).to eq(credentials.public_key_pem)
    end
    monolith_specs.each do |spec|
      expect(spec.env.fetch("TIMEKEEPING_DATABASE_URL", "")).to eq("")
      expect(spec.env.values.join("\n")).not_to include("timekeeping_secret")
      expect(spec.env["TIMEKEEPING_TOKEN_PRIVATE_KEY"]).to eq(credentials.private_key_pem)
    end
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "refuses to build when both applications would connect as the same database user" do
    # "In the local demo each application reads these keys from its own process environment, and the two applications share no database credential."
    expect do
      described_class.build(
        root: Rails.root.to_s,
        procfile: File.read(Rails.root.join("Procfile.timekeeping")),
        caller_env: {
          "PATH" => ENV.fetch("PATH", "/usr/bin"),
          "DB_USER" => "root",
          "DB_PASS" => "password",
          "TIMEKEEPING_DATABASE_URL" => "postgres://root:password@127.0.0.1:5432/timekeeping_development"
        },
        credentials: TimekeepingDemo::Credentials.generate,
        ports: { monolith: 3000, timekeeping: 3100 }
      )
    end.to raise_error(TimekeepingDemo::ConfigurationError)
  end
end

RSpec.describe TimekeepingDemo::RuntimePlan do
  it "passes no test hooks or unrelated caller secrets and binds every process to loopback" do
    specs = described_class.build(
      root: Rails.root.to_s,
      procfile: File.read(Rails.root.join("Procfile.timekeeping")),
      caller_env: {
        "PATH" => ENV.fetch("PATH", "/usr/bin"),
        "DB_USER" => "monolith_user",
        "TIMEKEEPING_DATABASE_URL" => "postgres://timekeeping_user@127.0.0.1:5432/timekeeping_development",
        "TIMEKEEPING_TEST_HOOKS" => "1",
        "SECRET_X" => "unrelated-caller-secret"
      },
      credentials: TimekeepingDemo::Credentials.generate,
      ports: { monolith: 3000, timekeeping: 3100 }
    )
    expect(specs).not_to be_empty

    url_keys = %w[TIMEKEEPING_BASE_URL MONOLITH_REFERENCE_URL MONOLITH_SNAPSHOT_URL TIMEKEEPING_PROJECTION_URL]
    specs.each do |spec|
      expect(spec.env).not_to have_key("TIMEKEEPING_TEST_HOOKS")
      expect(spec.env).not_to have_key("SECRET_X")
      expect(spec.env.values.join("\n")).not_to include("unrelated-caller-secret")
      spec.env.slice(*url_keys).each_value do |url|
        expect(URI.parse(url).host).to eq("127.0.0.1")
      end
      expect(spec.argv.join(" ")).not_to include("0.0.0.0")
    end
  end
end

# frozen_string_literal: true

require "rails_helper"
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
end

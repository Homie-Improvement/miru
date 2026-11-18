# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe TimekeepingDemo::CLI do
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
end

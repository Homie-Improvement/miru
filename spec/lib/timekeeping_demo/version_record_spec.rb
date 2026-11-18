# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe TimekeepingDemo::VersionRecord do
  def version_record_git(root, *args)
    output, status = Open3.capture2e("git", "-C", root, "-c", "user.name=Demo", "-c", "user.email=demo@example.com", *args)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output.strip
  end

  # A git repository with one monolith file and one timekeeping/ file, committed once.
  def with_version_record_repo
    Dir.mktmpdir("version-record") do |root|
      FileUtils.mkdir_p(File.join(root, "timekeeping"))
      File.write(File.join(root, "app.rb"), "puts :monolith\n")
      File.write(File.join(root, "timekeeping", "service.rb"), "puts :timekeeping\n")
      version_record_git(root, "init", "--quiet")
      version_record_git(root, "add", ".")
      version_record_git(root, "commit", "--quiet", "-m", "initial")
      yield root
    end
  end

  it "records the HEAD revision and each application's git tree for a clean checkout" do
    with_version_record_repo do |root|
      # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
      record = described_class.capture(root:)

      head = version_record_git(root, "rev-parse", "HEAD")
      expect(record.fetch("monolith"))
        .to include("revision" => head, "tree" => version_record_git(root, "rev-parse", "HEAD^{tree}"), "dirty" => false)
      expect(record.fetch("timekeeping"))
        .to include("revision" => head, "tree" => version_record_git(root, "rev-parse", "HEAD:timekeeping"), "dirty" => false)
      expect(head).to match(/\A\h{40}\z/)
    end
  end

  it "marks only the timekeeping application dirty when only timekeeping source changed, with a digest that tracks the change" do
    with_version_record_repo do |root|
      service_file = File.join(root, "timekeeping", "service.rb")
      File.write(service_file, "puts :changed_once\n")
      first = described_class.capture(root:)
      File.write(service_file, "puts :changed_twice\n")
      second = described_class.capture(root:)

      # The monolith's digest excludes timekeeping/, so an edit there leaves it clean.
      expect(first.fetch("monolith")).to include("dirty" => false)
      expect(first.fetch("timekeeping")).to include("dirty" => true)
      expect(first.dig("timekeeping", "diff_digest")).to be_a(String).and(be_present)
      # Two different uncommitted states must not be recorded as the same version.
      expect(second.dig("timekeeping", "diff_digest")).not_to eq(first.dig("timekeeping", "diff_digest"))
      expect(second.dig("timekeeping", "revision")).to eq(version_record_git(root, "rev-parse", "HEAD"))
      expect(JSON.generate(first)).not_to match(/KEY|TOKEN|postgres:/)
    end
  end
end

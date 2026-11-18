# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe TimekeepingDemo::VersionRecord do
  it "records the HEAD revision and each application's git tree for a clean checkout" do
    Dir.mktmpdir("version-record-clean") do |root|
      git = lambda do |*args|
        output, status = Open3.capture2e("git", "-C", root, *args)
        raise "git #{args.join(' ')} failed: #{output}" unless status.success?

        output.strip
      end
      FileUtils.mkdir_p(File.join(root, "timekeeping"))
      File.write(File.join(root, "app.rb"), "puts :monolith\n")
      File.write(File.join(root, "timekeeping", "service.rb"), "puts :timekeeping\n")
      git.call("init", "--quiet")
      git.call("add", ".")
      git.call("-c", "user.name=Demo", "-c", "user.email=demo@example.com", "commit", "--quiet", "-m", "initial")

      # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
      record = described_class.capture(root:)

      head = git.call("rev-parse", "HEAD")
      expect(record.fetch("monolith")).to include("revision" => head, "tree" => git.call("rev-parse", "HEAD^{tree}"), "dirty" => false)
      expect(record.fetch("timekeeping")).to include("revision" => head, "tree" => git.call("rev-parse", "HEAD:timekeeping"), "dirty" => false)
      expect(head).to match(/\A\h{40}\z/)
    end
  end
end

RSpec.describe TimekeepingDemo::VersionRecord do
  it "marks only the timekeeping application dirty when only timekeeping source changed, with a digest that tracks the change" do
    Dir.mktmpdir("version-record-dirty") do |root|
      git = lambda do |*args|
        output, status = Open3.capture2e("git", "-C", root, *args)
        raise "git #{args.join(' ')} failed: #{output}" unless status.success?

        output.strip
      end
      FileUtils.mkdir_p(File.join(root, "timekeeping"))
      File.write(File.join(root, "app.rb"), "puts :monolith\n")
      service_file = File.join(root, "timekeeping", "service.rb")
      File.write(service_file, "puts :timekeeping\n")
      git.call("init", "--quiet")
      git.call("add", ".")
      git.call("-c", "user.name=Demo", "-c", "user.email=demo@example.com", "commit", "--quiet", "-m", "initial")

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
      expect(second.dig("timekeeping", "revision")).to eq(git.call("rev-parse", "HEAD"))
    end
  end
end

RSpec.describe TimekeepingDemo::VersionRecord do
  # "`bin/timekeeping-demo up` starts the runtime and records each application's version or artifact digest to a file."
  it "records a revision and source tree for each application and marks only the edited application dirty" do
    Dir.mktmpdir("timekeeping-demo-versions") do |root|
      git = lambda do |*args|
        output, status = Open3.capture2e("git", "-c", "user.name=Spec", "-c", "user.email=spec@example.com", *args, chdir: root)
        raise output unless status.success?

        output
      end
      git.call("init", "-q")
      FileUtils.mkdir_p(File.join(root, "timekeeping"))
      File.write(File.join(root, "app.rb"), "monolith\n")
      File.write(File.join(root, "timekeeping", "service.rb"), "timekeeping\n")
      git.call("add", ".")
      git.call("commit", "-q", "-m", "initial")
      head = git.call("rev-parse", "HEAD").strip

      clean = described_class.capture(root:)
      %w[monolith timekeeping].each do |app|
        expect(clean.fetch(app).fetch("revision")).to eq(head)
        expect(clean.fetch(app).fetch("tree")).to match(/\A\h{40}\z/)
        expect(clean.fetch(app).fetch("dirty")).to be(false)
      end
      expect(clean.dig("timekeeping", "tree")).to eq(git.call("rev-parse", "HEAD:timekeeping").strip)

      File.write(File.join(root, "timekeeping", "service.rb"), "timekeeping changed\n")
      dirty = described_class.capture(root:)
      expect(dirty.dig("timekeeping", "dirty")).to be(true)
      expect(dirty.dig("timekeeping", "diff_digest")).to be_a(String).and(be_present)
      expect(dirty.dig("monolith", "dirty")).to be(false)

      expect(JSON.generate(dirty)).not_to match(/KEY|TOKEN|postgres:/)
    end
  end
end

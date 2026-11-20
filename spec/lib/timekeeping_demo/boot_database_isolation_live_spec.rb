# frozen_string_literal: true

require "rails_helper"
require "open3"
require "securerandom"
require "tmpdir"
require "uri"
require Rails.root.join("lib", "timekeeping_demo", "version_record").to_s

RSpec.describe TimekeepingDotenvTree do
  it "building a tree with its own git repository leaves the checkout's HEAD, index and .env files untouched" do
    git = lambda do |dir, *args|
      output, status = Open3.capture2("git", *args, chdir: dir)
      expect(status.success?).to be(true)
      output
    end
    checkout = Rails.root.to_s
    env_files_before = Rails.root.glob(".env*").map(&:to_s).sort
    head_before = git.call(checkout, "rev-parse", "HEAD")
    status_before = git.call(checkout, "status", "--porcelain", "--untracked-files=no")
    probe = "dotenv-probe-#{SecureRandom.hex(8)}"

    Dir.mktmpdir do |dir|
      tree = File.realpath(dir)
      described_class.build(tree, dotenv: "PGAPPNAME=#{probe}\n", own_git: true)

      # The tree's commit must land in a repository of its own: a symlinked
      # .git would write the commit into the developer's checkout.
      expect(File.symlink?(File.join(tree, ".git"))).to be(false)
      expect(git.call(tree, "rev-parse", "--show-toplevel").strip).to eq(tree)
      expect(File.read(File.join(tree, ".env.test.local"))).to eq("PGAPPNAME=#{probe}\n")
    end

    expect(git.call(checkout, "rev-parse", "HEAD")).to eq(head_before)
    expect(git.call(checkout, "status", "--porcelain", "--untracked-files=no")).to eq(status_before)
    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(env_files_before)
    expect(Rails.root.glob(".env*").any? { |path| File.read(path).include?(probe) }).to be(false)
  end
end

RSpec.describe "Timekeeping demo boot database isolation tree" do
  it "version capture succeeds in a dotenv tree built with its own git repository and records both applications" do
    Dir.mktmpdir do |dir|
      tree = File.realpath(dir)
      built = begin
        TimekeepingDotenvTree.build(tree, dotenv: "PGAPPNAME=boot-isolation-version-probe\n", own_git: true)
        true
      rescue ArgumentError
        false
      end
      expect(built).to be(true)

      # The launcher captures versions before any app starts, so a capture
      # that raises here would stop the boot before any connection exists.
      record = TimekeepingDemo::VersionRecord.capture(root: tree)
      expect(record.keys).to eq(%w[monolith timekeeping])
      expect(record.values.map { |entry| entry.fetch("revision") }.uniq.size).to eq(1)
      expect(File.symlink?(File.join(tree, ".git"))).to be(false)
    end
  end
end

RSpec.describe "Timekeeping demo boot database isolation tree" do
  it "a dotenv tree with its own git leaves the checkout's env files and git history unchanged and repeated captures add no commit" do
    env_files_before = Rails.root.glob(".env*").map(&:to_s).sort
    checkout_head_before, = Open3.capture2("git", "rev-parse", "HEAD", chdir: Rails.root.to_s)
    tree_path = nil

    Dir.mktmpdir do |dir|
      tree = File.realpath(dir)
      tree_path = tree
      TimekeepingDotenvTree.build(tree, dotenv: "DB_USER=boot-isolation-conflict\n", own_git: true)

      first = TimekeepingDemo::VersionRecord.capture(root: tree)
      second = TimekeepingDemo::VersionRecord.capture(root: tree)
      expect(second.transform_values { |entry| entry.slice("revision", "tree") })
        .to eq(first.transform_values { |entry| entry.slice("revision", "tree") })

      commits, = Open3.capture2("git", "rev-list", "--count", "HEAD", chdir: tree)
      expect(commits.strip).to eq("1")
      expect(File.read(File.join(tree, ".env.test.local"))).to eq("DB_USER=boot-isolation-conflict\n")
    end

    checkout_head_after, = Open3.capture2("git", "rev-parse", "HEAD", chdir: Rails.root.to_s)
    expect(checkout_head_after).to eq(checkout_head_before)
    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(env_files_before)
    expect(File.exist?(tree_path)).to be(false)
  end
end

RSpec.describe TimekeepingDotenvTree, "for a boot of bin/timekeeping-demo up" do
  it "the launcher's version capture succeeds in a dotenv tree built with its own git repository" do
    checkout_env_files_before = Rails.root.glob(".env*").map(&:to_s).sort

    Dir.mktmpdir("boot-isolation-version-tree") do |dir|
      tree = File.realpath(dir)
      described_class.build(tree, dotenv: "PGAPPNAME=version-capture-probe\n", own_git: true)

      # `bin/timekeeping-demo up` captures versions before it starts any app, so
      # a tree the capture fails in can never boot either application.
      versions = nil
      expect { versions = TimekeepingDemo::VersionRecord.capture(root: tree) }.not_to raise_error
      expect(versions.keys).to contain_exactly("monolith", "timekeeping")
      expect(versions.values.map { |entry| entry.fetch("revision") }.uniq.size).to eq(1)
      expect(File.symlink?(File.join(tree, ".git"))).to be(false)
      expect(File.directory?(File.join(tree, ".git"))).to be(true)
    end

    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(checkout_env_files_before)
  end
end

RSpec.describe TimekeepingDotenvTree, "entry points for a boot of bin/timekeeping-demo up" do
  it "every monolith entry point in the dotenv tree is a real copy whose app root is the tree" do
    Dir.mktmpdir("boot-isolation-entry-tree") do |dir|
      tree = File.realpath(dir)
      described_class.build(tree, dotenv: "PGAPPNAME=entry-point-probe\n")

      # These files find the app root from their own resolved location, so a
      # symlink would boot the real checkout and read its .env files instead.
      scripts = %w[bin/timekeeping-demo bin/timekeeping-demo-queue bin/rails]
      top_level = %w[Rakefile config.ru]
      (scripts + top_level).each do |path|
        full = File.join(tree, path)
        expect(File.symlink?(full)).to be(false), "#{path} must be a real copy"
        expect(File.file?(full)).to be(true), "#{path} must exist in the tree"
        expect(File.read(full)).to eq(Rails.root.join(path).read)
      end
      scripts.each do |path|
        full = File.join(tree, path)
        expect(File.executable?(full)).to be(true), "#{path} must stay executable"
        expect(File.expand_path("..", File.dirname(File.realpath(full)))).to eq(tree)
      end
      top_level.each do |path|
        expect(File.dirname(File.realpath(File.join(tree, path)))).to eq(tree)
      end
      expect(File.read(File.join(tree, ".env.test.local"))).to eq("PGAPPNAME=entry-point-probe\n")
      expect(Dir.children(tree).grep(/\A\.env/)).to eq([".env.test.local"])
      # Without own_git: the tree keeps pointing at the checkout's repository.
      expect(File.symlink?(File.join(tree, ".git"))).to be(true)
    end
  end
end

RSpec.describe IntegratedRuntime, "booted from a tree with a conflicting dotenv file" do
  def boot_isolation_users_tagged(probe)
    sql = ActiveRecord::Base.sanitize_sql_array(
      ["SELECT DISTINCT usename FROM pg_stat_activity WHERE application_name = ?", probe]
    )
    ActiveRecord::Base.connection.select_values(sql).sort
  end

  def boot_isolation_url_with_application_name(url, name)
    uri = URI.parse(url)
    query = (uri.query ? URI.decode_www_form(uri.query) : []) + [["application_name", name]]
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  # "A spec boots the monolith and Timekeeping through bin/timekeeping-demo with a temporary dotenv file that sets conflicting DATABASE_URL, DB_USER and PG\* values, and asserts that each app's live connection reports its own distinct current_user."
  it "booted through bin/timekeeping-demo with a conflicting dotenv file, each app's live connection runs as its own distinct database user" do
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    WebMock.disable_net_connect!(allow_localhost: true)
    checkout_env_files_before = Rails.root.glob(".env*").map(&:to_s).sort
    monolith_probe = "boot-isolation-monolith-#{SecureRandom.hex(8)}"
    timekeeping_probe = "boot-isolation-timekeeping-#{SecureRandom.hex(8)}"
    env = ENV.to_h.merge(
      "TIMEKEEPING_DATABASE_URL" => boot_isolation_url_with_application_name(ENV.fetch("TIMEKEEPING_DATABASE_URL"), timekeeping_probe)
    )
    login_user = TimekeepingDemo::RuntimePlan.default_login_user
    timekeeping_user = TimekeepingDemo::RuntimePlan.url_user(env.fetch("TIMEKEEPING_DATABASE_URL")) || login_user
    monolith_user = TimekeepingDemo::RuntimePlan.monolith_database_user(env) || login_user
    expect(timekeeping_user).not_to eq(monolith_user)

    observed = {}
    groups = []
    Dir.mktmpdir("boot-isolation-tree") do |dir|
      tree = File.realpath(dir)
      host = ENV["DB_HOST"].presence || "localhost"
      monolith_database = ActiveRecord::Base.connection_db_config.database
      # Every conflicting value names the Timekeeping user, so a leak into the
      # monolith makes both apps report the same user. Targets are _test
      # databases or a socket directory that does not exist.
      dotenv = <<~DOTENV
        DATABASE_URL=postgres://#{URI.encode_www_form_component(timekeeping_user)}@#{host}/#{monolith_database}
        DB_USER=#{timekeeping_user}
        PGUSER=#{timekeeping_user}
        PGPASSWORD=boot-isolation-dotenv-conflict
        PGHOST=#{File.join(tree, 'no-such-socket-dir')}
        PGAPPNAME=#{monolith_probe}
      DOTENV
      TimekeepingDotenvTree.build(tree, dotenv:, own_git: true)

      described_class.run(root: tree, env:) do |runtime|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
        loop do
          observed = { monolith: boot_isolation_users_tagged(monolith_probe),
                       timekeeping: boot_isolation_users_tagged(timekeeping_probe) }
          break if observed.values.none?(&:empty?) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.5
        end
        groups = (runtime.process_groups + described_class.recorded_groups(tree)).uniq
      end
    end

    # A monolith backend carrying the probe proves the tree's dotenv file was
    # loaded and reached the live connection; an empty list must not pass.
    expect(observed.fetch(:monolith)).to eq([monolith_user])
    expect(observed.fetch(:timekeeping)).to eq([timekeeping_user])
    expect(observed.fetch(:monolith)).not_to eq(observed.fetch(:timekeeping))
    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(checkout_env_files_before)
    # The groups were read from the tree's own groups file, so this also shows
    # the launcher ran with the tree as its root.
    expect(groups.size).to be > 1
    expect(groups.select { |group| IntegratedRuntime.group_alive?(group) }).to eq([])
  end

  # Without the dotenv file the monolith's connections carry no probe, and the
  # boot example must then fail rather than pass on an empty list.
  it "no live connection carries a probe that no dotenv file set" do
    expect(boot_isolation_users_tagged("boot-isolation-unset-#{SecureRandom.hex(8)}")).to eq([])
  end
end

RSpec.describe IntegratedRuntime, "booted from a tree without the empty DATABASE_URL deletion" do
  # "They do not exercise dotenv loading, the new deletion of an empty DATABASE_URL in config/application.rb, or the resulting database connection."
  it "a tree whose application.rb keeps an empty DATABASE_URL fails to boot through bin/timekeeping-demo" do
    skip "Set TIMEKEEPING_LIVE=1 to start the real demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    WebMock.disable_net_connect!(allow_localhost: true)
    checkout_env_files_before = Rails.root.glob(".env*").map(&:to_s).sort
    # The launcher hands the monolith DATABASE_URL="" only when the caller has none.
    env = ENV.to_h.except("DATABASE_URL")

    Dir.mktmpdir("boot-isolation-control-tree") do |dir|
      tree = File.realpath(dir)
      TimekeepingDotenvTree.build(tree, dotenv: "PGAPPNAME=boot-isolation-control-#{SecureRandom.hex(8)}\n", own_git: true)
      application = File.join(tree, "config", "application.rb")
      # Editing a symlink here would change the checkout's own file.
      expect(File.symlink?(application)).to be(false)
      deletion = 'ENV.delete("DATABASE_URL") if ENV["DATABASE_URL"] == ""'
      source = File.read(application)
      expect(source).to include(deletion)
      File.write(application, source.sub(deletion, ""))

      runtime = nil
      begin
        expect { runtime = described_class.start(root: tree, env:) }.to raise_error(IntegratedRuntime::BootError)
      ensure
        runtime&.stop!
      end
    end

    expect(Rails.root.join("config", "application.rb").read).to include('ENV.delete("DATABASE_URL") if ENV["DATABASE_URL"] == ""')
    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(checkout_env_files_before)
  end
end

RSpec.describe TimekeepingDotenvTree do
  # "A spec boots the monolith and Timekeeping through bin/timekeeping-demo with a temporary dotenv file that sets conflicting DATABASE_URL, DB_USER and PG\* values, and asserts that each app's live connection reports its own distinct current_user."
  # These files find the app root from their own resolved location. A symlink to the checkout
  # would boot the checkout's application, read its .env files, and never read the tree's file.
  it "every monolith entry point in the dotenv tree resolves its app root to the tree, not the real checkout, so db:prepare and the servers read the tree's dotenv file" do
    Dir.mktmpdir("boot-isolation-entry-tree") do |dir|
      tree = File.realpath(dir)
      described_class.build(tree, dotenv: "PGAPPNAME=boot-isolation-entry-probe\n")

      scripts = %w[bin/timekeeping-demo bin/timekeeping-demo-queue bin/rails]
      roots = scripts.index_with do |path|
        File.expand_path("..", File.dirname(File.realpath(File.join(tree, path))))
      end
      top_level = %w[Rakefile config.ru].index_with do |path|
        File.dirname(File.realpath(File.join(tree, path)))
      end

      expect(roots).to eq(scripts.index_with(tree))
      expect(top_level).to eq("Rakefile" => tree, "config.ru" => tree)
      expect(scripts.all? { |path| File.executable?(File.join(tree, path)) }).to be(true)
    end
  end
end

RSpec.describe TimekeepingDotenvTree do
  # "A spec boots the monolith and Timekeeping through bin/timekeeping-demo with a temporary dotenv file that sets conflicting DATABASE_URL, DB_USER and PG\* values, and asserts that each app's live connection reports its own distinct current_user."
  # The temporary dotenv file must never reach the developer's checkout, and the tree's own
  # git commit must not land in the checkout's repository.
  it "building a dotenv tree with its own git repository leaves the checkout's env files and git history untouched and holds no env file but the conflicting one" do
    checkout_env_files_before = Rails.root.glob(".env*").map(&:to_s).sort
    checkout_head_before, = Open3.capture2("git", "rev-parse", "HEAD", chdir: Rails.root.to_s)

    Dir.mktmpdir("boot-isolation-untouched-tree") do |dir|
      tree = File.realpath(dir)
      described_class.build(tree, dotenv: "DB_USER=boot_isolation_conflict\nPGAPPNAME=boot-isolation-untouched\n",
                                  own_git: true)

      expect(Dir.glob(".env*", File::FNM_DOTMATCH, base: tree)).to eq([".env.test.local"])
      expect(File.read(File.join(tree, ".env.test.local"))).to include("DB_USER=boot_isolation_conflict")
    end

    checkout_head_after, = Open3.capture2("git", "rev-parse", "HEAD", chdir: Rails.root.to_s)
    expect(Rails.root.glob(".env*").map(&:to_s).sort).to eq(checkout_env_files_before)
    expect(checkout_head_after).to eq(checkout_head_before)
  end
end

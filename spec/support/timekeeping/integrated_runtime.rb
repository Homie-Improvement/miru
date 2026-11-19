# frozen_string_literal: true

require "fileutils"
require "net/http"
require "socket"
require "tempfile"

# spec/rails_helper.rb requires support files in sorted order, and this file
# sorts before owner_state.rb. Requiring it here registers the owner-state
# hook first, so the runtime hook below starts after the owner state is set.
require_relative "owner_state"
require_relative "timekeeping_database_reset"

# Starts the whole local demo runtime (`bin/timekeeping-demo up`) for a live
# proof example and always stops it again.
#
# The test process makes the credentials and passes them only in the
# launcher's spawn environment, so it can authenticate to both apps. The
# launcher's supervisor starts each app in its own process group and records
# every group in tmp/timekeeping-demo/process_groups; teardown reads that file,
# because a launcher killed before it stopped its apps leaves them running.
#
# No error raised here carries an environment value or a child's output: both
# can hold the private key, and errors end up in CI logs.
class IntegratedRuntime
  class BootError < StandardError; end

  HOST = "127.0.0.1"
  BOOT_TIMEOUT_SECONDS = 180
  POLL_SECONDS = 0.5
  # Teardown waits longer than the supervisor's own graceful stop, so the
  # supervisor finishes stopping its apps before anything is killed.
  STOP_MARGIN_SECONDS = 5
  GROUPS_FILE = File.join(TimekeepingDemo::CLI::DEFAULT_STATE_DIR, TimekeepingDemo::CLI::PROCESS_GROUPS_FILE)
  # Procfile.timekeeping starts the Timekeeping server with this fixed pid file.
  # A server killed with KILL leaves it, and the next server refuses to boot.
  TIMEKEEPING_PID_FILE = File.join("timekeeping", "tmp", "pids", "timekeeping-demo.pid")
  TIMEKEEPING_DATABASE_URL = TimekeepingDatabaseReset::DATABASE_URL_KEY
  # A group id of 0 or 1 would make Process.kill signal the caller's own group
  # or every process the user owns, so only larger whole numbers are read.
  GROUP_LINE = /\A\d+\z/
  SMALLEST_GROUP = 2

  attr_reader :monolith_url, :timekeeping_url, :credentials

  # Refuses to start while an earlier runtime is still running, refuses
  # databases whose names do not end in _test, prepares and resets the
  # Timekeeping database, then starts the launcher and waits until both apps
  # answer. Anything that fails after the launcher started stops it first.
  #
  # Just before the launcher starts, the queue ledger is activated and its two
  # control jobs are enqueued, so stop! and every reset from here on record
  # any job a non-dedicated worker ran. Tests that boot a fake launcher pass a ledger of
  # their own, so the suite's shared ledger stays inactive.
  def self.start(root:, env:, owner_state: TimekeepingOwnerState::SELECTED, ledger: TimekeepingQueueLedger.session)
    refuse_if_running!(root:)
    TestDatabaseGuard.require_test_database!(monolith_database_name)
    # The launcher's monolith prefers a caller DATABASE_URL over the test
    # process's own database, so that target is checked as well.
    child_monolith_url = env[TimekeepingDemo::RuntimePlan::MONOLITH_DATABASE_URL].to_s
    require_test_database_url!(child_monolith_url) unless child_monolith_url.strip.empty?
    require_test_database_url!(timekeeping_database_url(env))
    credentials = TimekeepingDemo::Credentials.generate
    ports = { monolith: free_port, timekeeping: free_port }
    clear_leftovers!(root)
    prepare_timekeeping!(root:, env:, credentials:, ports:)
    reset_timekeeping!(owner_state, env)
    ledger.activate!(env:)
    ledger.open_window!
    runtime = new(root:, env:, credentials:, ports:, ledger:)
    ledger.register_runtime(root, runtime:)
    runtime.tap(&:boot!)
  end

  def self.run(root:, env:, owner_state: TimekeepingOwnerState::SELECTED, ledger: TimekeepingQueueLedger.session)
    runtime = start(root:, env:, owner_state:, ledger:)
    yield runtime
  ensure
    runtime&.stop!
  end

  # Raises while the groups file lists a live group, so a second runtime never
  # starts beside one whose workers are still running. Answers nil otherwise.
  def self.refuse_if_running!(root:)
    return nil unless recorded_groups(root).any? { |group| group_alive?(group) }

    raise BootError, "a demo runtime recorded in #{GROUPS_FILE} is still running; stop it before starting another"
  end

  def self.parse_groups(text)
    # A last line with no newline may be a partial write ("424" of "4242"),
    # which could name a group this harness never started.
    text.each_line.filter_map { |line| line.chomp if line.end_with?("\n") }.grep(GROUP_LINE).map { |line| Integer(line, 10) }.select { |id| id >= SMALLEST_GROUP }
  end

  # The launcher's spawn environment, arguments and options. The credentials
  # are merged last, so stale keys inherited from the test process never win.
  def self.launch(root:, env:, credentials:, ports:)
    port_env = TimekeepingDemo::CLI::PORT_KEYS.to_h { |app, key| [key, ports.fetch(app).to_s] }
    spawn_env = env.merge("RAILS_ENV" => "test").merge(port_env).merge(credentials.to_env)
    [spawn_env, [File.join(root, "bin", "timekeeping-demo"), "up"], { chdir: root, pgroup: true }]
  end

  # Resets the monolith test database for a runtime example, after checking
  # its name. A seeded example gets a freshly loaded two-tenant seed, the owner
  # state and a reset Timekeeping admission row; any other example gets empty
  # tables with the owner state the emptying reset put back.
  def self.clean_monolith!(seeded: false, owner_state: TimekeepingOwnerState::SELECTED, env: ENV)
    TestDatabaseGuard.require_test_database!(monolith_database_name)
    if seeded
      TestDatabaseCleanup.reset_seeded_committed!(as_of: TestDatabaseCleanup.seed_as_of, state: owner_state, env:)
    else
      TestDatabaseCleanup.delete_all_committed!
      TimekeepingOwnerState.apply!(owner_state) if owner_state
    end
    nil
  end

  def self.recorded_groups(root)
    path = File.join(root, GROUPS_FILE)
    File.exist?(path) ? parse_groups(File.read(path)) : []
  end

  # A group that exists but belongs to another user is not one this harness
  # started, so it counts as gone.
  def self.group_alive?(group)
    Process.kill(0, -group)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def self.monolith_database_name
    ActiveRecord::Base.connection_db_config.database
  end

  def self.timekeeping_database_url(env)
    raise BootError, "#{TIMEKEEPING_DATABASE_URL} must name the Timekeeping test database" unless env.key?(TIMEKEEPING_DATABASE_URL)

    env.fetch(TIMEKEEPING_DATABASE_URL)
  end

  # libpq (used by the reset) and Active Record (used by db:prepare and the
  # apps) can read different databases from one URL, for example a path name
  # and a dbname query parameter. Both readings must name a test database.
  # Public so specs that write rows into the Timekeeping database apply the
  # same check before they touch it.
  def self.require_test_database_url!(url)
    TestDatabaseGuard.require_test_database!(TimekeepingDatabaseReset.database_name(url))
    TestDatabaseGuard.require_test_database!(active_record_database_name(url))
  end

  def self.active_record_database_name(url)
    ActiveRecord::DatabaseConfigurations::UrlConfig.new("test", "harness_guard", url, { adapter: "postgresql" }).database
  rescue ActiveRecord::DatabaseConfigurations::InvalidConfigurationError, URI::Error
    nil
  end

  def self.free_port
    server = TCPServer.new(HOST, 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Called only after refuse_if_running! passed: old ids in the groups file
  # could since have been reused by unrelated processes, which teardown must
  # never signal.
  def self.clear_leftovers!(root)
    groups_path = File.join(root, GROUPS_FILE)
    FileUtils.mkdir_p(File.dirname(groups_path))
    File.write(groups_path, "")
    FileUtils.rm_f(File.join(root, TIMEKEEPING_PID_FILE))
  end

  # Runs db:prepare for Timekeeping with exactly the environment the demo
  # gives Timekeeping (RuntimePlan), and nothing inherited, so a private key
  # in the caller's shell never reaches it.
  def self.prepare_timekeeping!(root:, env:, credentials:, ports:)
    procfile = File.read(File.join(root, TimekeepingDemo::CLI::PROCFILE))
    spec = TimekeepingDemo::RuntimePlan.build(root:, procfile:, caller_env: env.merge("RAILS_ENV" => "test"),
                                              credentials:, ports:)
                                       .find { |candidate| candidate.app == :timekeeping }
    pid = Bundler.with_unbundled_env do
      Process.spawn(spec.env, *TimekeepingDemo::Supervisor::PREPARE_COMMAND,
                    chdir: spec.chdir, unsetenv_others: true, pgroup: true, out: File::NULL, err: File::NULL)
    end
    status = wait_for_prepare(pid)
    raise BootError, boot_error_message("timekeeping", "db:prepare did not finish") unless status
    raise BootError, boot_error_message("timekeeping", "db:prepare failed") unless status.success?
  end

  # Answers the exit status, or nil after killing and reaping the group when
  # db:prepare outlives the boot timeout or the wait is interrupted.
  def self.wait_for_prepare(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT_SECONDS
    status = nil
    begin
      until status || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        _, status = Process.wait2(pid, Process::WNOHANG)
        sleep POLL_SECONDS unless status
      end
      status
    ensure
      unless status
        kill_group(pid)
        Process.wait(pid)
      end
    end
  end

  # A connection error can carry the database host, so it is replaced.
  def self.reset_timekeeping!(owner_state, env)
    TimekeepingDatabaseReset.reset!(owner_state, env:)
  rescue PG::Error
    raise BootError, boot_error_message("timekeeping", "database could not be reset"), cause: nil
  end

  # Every boot error names only the app and the boot timeout: the environment
  # and the children's output can hold credentials.
  def self.boot_error_message(app, problem)
    "#{app} #{problem} (boot timeout #{BOOT_TIMEOUT_SECONDS} s)"
  end

  def self.kill_group(group)
    Process.kill("KILL", -group)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  private_class_method :monolith_database_name, :timekeeping_database_url, :active_record_database_name,
                       :free_port, :clear_leftovers!, :prepare_timekeeping!, :wait_for_prepare, :reset_timekeeping!

  def initialize(root:, env:, credentials:, ports:, ledger: TimekeepingQueueLedger.session)
    @root = root
    @ledger = ledger
    @env = env
    @credentials = credentials
    @ports = ports
    @monolith_url = "http://#{HOST}:#{ports.fetch(:monolith)}"
    @timekeeping_url = "http://#{HOST}:#{ports.fetch(:timekeeping)}"
    @launcher = nil
    @stopped = false
  end

  # The launcher's group and every group its supervisor recorded so far.
  def process_groups
    ([@launcher].compact + self.class.recorded_groups(@root)).uniq
  end

  # Stops the launcher on every way out short of readiness, an Interrupt
  # included, because the caller never receives a runtime it could stop.
  def boot!
    ready = false
    @log = Tempfile.new(["timekeeping-demo-runtime", ".log"])
    spawn_env, argv, options = self.class.launch(root: @root, env: @env, credentials:, ports: @ports)
    @launcher = Process.spawn(spawn_env, *argv, **options, out: @log.path, err: [:child, :out])
    wait_until_ready
    ready = true
  ensure
    stop! unless ready
  end

  # Sends TERM to the launcher, whose supervisor then stops its apps; waits
  # past the supervisor's own grace period; then kills every recorded group
  # still alive and waits for them to be gone. Raises when a group outlives
  # the KILL, so no database reset runs beside it. Safe to call again: a call
  # after a full stop does nothing.
  #
  # Once every group is gone no worker can run another job, so the ledger
  # collects and records the controls' status then. The control window stays
  # open until the next reset checks the controls again.
  def stop!
    return if @stopped

    signal_launcher("TERM")
    wait_for_groups_gone(TimekeepingDemo::Supervisor::STOP_GRACE_SECONDS + STOP_MARGIN_SECONDS)
    process_groups.each { |group| self.class.kill_group(group) if self.class.group_alive?(group) }
    gone = wait_for_groups_gone(STOP_MARGIN_SECONDS)
    reap_launcher(0)
    @log&.close!
    raise BootError, "process groups of the demo runtime were still alive after KILL" unless gone

    @stopped = true
    @ledger.after_stop!
  end

  def inspect
    "#<#{self.class.name} monolith_url=#{monolith_url} timekeeping_url=#{timekeeping_url} [credentials hidden]>"
  end
  alias_method :to_s, :inspect

  private

    def wait_until_ready
      deadline = monotonic_now + BOOT_TIMEOUT_SECONDS
      loop do
        if reap_launcher(Process::WNOHANG)
          raise BootError, self.class.boot_error_message("launcher", "exited before the runtime was ready")
        end

        waiting = { "monolith" => monolith_ready?, "timekeeping" => timekeeping_ready? }.reject { |_app, ready| ready }.keys
        return if waiting.empty?
        raise BootError, self.class.boot_error_message(waiting.join(" and "), "not ready") if monotonic_now > deadline

        sleep POLL_SECONDS
      end
    end

    # Answers true once no recorded group has a live member. Reaping comes
    # first: an exited child that was not reaped still counts as a member.
    def wait_for_groups_gone(seconds)
      deadline = monotonic_now + seconds
      loop do
        reap_launcher(Process::WNOHANG)
        process_groups.each { |group| reap_exited_members(group) }
        return true if process_groups.none? { |group| self.class.group_alive?(group) }
        return false if monotonic_now > deadline

        sleep POLL_SECONDS
      end
    end

    # Reaps exited members of the group that are this process's own children;
    # members that are not are reaped by their own parent or by init.
    def reap_exited_members(group)
      loop { break if Process.wait(-group, Process::WNOHANG).nil? }
    rescue Errno::ECHILD
      nil
    end

    def monolith_ready?
      get(URI.join(monolith_url, "/health")).is_a?(Net::HTTPSuccess)
    end

    # Authenticated, so a server that is not this runtime's Timekeeping, such
    # as one that took the port after it was picked, never counts as ready.
    def timekeeping_ready?
      get(URI.join(timekeeping_url, "/internal/v1/metrics"), "Bearer #{credentials.service_token}").is_a?(Net::HTTPOK)
    end

    def get(uri, authorization = nil)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = authorization if authorization
      Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
    rescue SystemCallError, IOError, Net::ProtocolError, Timeout::Error
      nil
    end

    def signal_launcher(signal)
      Process.kill(signal, -@launcher) if @launcher
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Answers true once the launcher has exited and been reaped, or was never
    # started. flags 0 blocks until it exits.
    def reap_launcher(flags)
      return true unless @launcher
      return true if @launcher_reaped

      @launcher_reaped = !Process.wait(@launcher, flags).nil?
    rescue Errno::ECHILD
      @launcher_reaped = true
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end

RSpec.configure do |config|
  # Runs before every other before hook, including the committed_data and
  # without_transaction resets, so a skipped example or one refused because an
  # earlier runtime is live never reaches any reset. Only after the check
  # passes may this example's resets run (TestDatabaseCleanup.reset_withheld?).
  config.prepend_before(:each, :integrated_runtime) do |example|
    skip "Set TIMEKEEPING_LIVE=1 to start the demo runtime" unless ENV["TIMEKEEPING_LIVE"] == "1"

    IntegratedRuntime.refuse_if_running!(root: Rails.root.to_s)
    example.metadata[:integrated_runtime_resets_allowed] = true
  end

  # Registered after the cleaner and owner-state hooks (see the require above):
  # the monolith is emptied, or reseeded for a seeded committed example, and
  # the example's owner state put back before the runtime starts in that
  # state. The reseed is needed because this clean would otherwise delete the
  # seed the committed_data hook loaded. Resets are withheld while start runs:
  # a start that fails because a group survived its own cleanup leaves nothing
  # safe to reset beside.
  config.before(:each, :integrated_runtime) do |example|
    owner_state = TimekeepingOwnerState.for_example(example.metadata)
    IntegratedRuntime.clean_monolith!(
      seeded: TestDatabaseCleanup.seeded_committed?(example.metadata), owner_state:, env: ENV.to_h
    )
    example.metadata[:integrated_runtime_resets_allowed] = false
    @integrated_runtime = IntegratedRuntime.start(root: Rails.root.to_s, env: ENV.to_h, owner_state:)
    example.metadata[:integrated_runtime_resets_allowed] = true
  end

  # A plain after hook runs before every append_after cleaner, so the runtime's
  # workers and relay are stopped before any reset. Resets stay withheld until
  # stop! confirms every group is gone: if it raises, no cleaner runs beside a
  # surviving process. A start that failed after stopping cleanly also leaves
  # them withheld; the next runtime example cleans before it starts.
  config.after(:each, :integrated_runtime) do |example|
    next unless example.metadata[:integrated_runtime_resets_allowed]

    example.metadata[:integrated_runtime_resets_allowed] = false
    @integrated_runtime&.stop!
    example.metadata[:integrated_runtime_resets_allowed] = true
    IntegratedRuntime.clean_monolith!(owner_state: TimekeepingOwnerState.for_example(example.metadata))
  end
end

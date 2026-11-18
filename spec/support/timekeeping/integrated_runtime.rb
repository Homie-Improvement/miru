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
  def self.start(root:, env:, owner_state: TimekeepingOwnerState::SELECTED)
    refuse_if_running!(root:)
    TestDatabaseGuard.require_test_database!(monolith_database_name)
    # The launcher's monolith prefers a caller DATABASE_URL over the test
    # process's own database, so that target is checked as well.
    child_monolith_url = env[TimekeepingDemo::RuntimePlan::MONOLITH_DATABASE_URL].to_s
    TestDatabaseGuard.require_test_database!(TimekeepingDatabaseReset.database_name(child_monolith_url)) unless child_monolith_url.strip.empty?
    TestDatabaseGuard.require_test_database!(timekeeping_database_name(env))
    credentials = TimekeepingDemo::Credentials.generate
    ports = { monolith: free_port, timekeeping: free_port }
    clear_leftovers!(root)
    prepare_timekeeping!(root:, env:, credentials:, ports:)
    reset_timekeeping!(owner_state, env)
    new(root:, env:, credentials:, ports:).tap(&:boot!)
  end

  def self.run(root:, env:, owner_state: TimekeepingOwnerState::SELECTED)
    runtime = start(root:, env:, owner_state:)
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

  # Empties the monolith test database for a runtime example, after checking
  # its name, and puts back the selected owner state the emptying reset.
  def self.clean_monolith!(owner_state: TimekeepingOwnerState::SELECTED)
    TestDatabaseGuard.require_test_database!(monolith_database_name)
    TestDatabaseCleanup.delete_all_committed!
    TimekeepingOwnerState.apply!(owner_state) if owner_state
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

  def self.timekeeping_database_name(env)
    raise BootError, "#{TIMEKEEPING_DATABASE_URL} must name the Timekeeping test database" unless env.key?(TIMEKEEPING_DATABASE_URL)

    TimekeepingDatabaseReset.database_name(env.fetch(TIMEKEEPING_DATABASE_URL))
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
    status = nil
    begin
      _, status = Process.wait2(pid)
    ensure
      kill_group(pid) unless status
    end
    raise BootError, "timekeeping db:prepare failed" unless status.success?
  end

  # A connection error can carry the database host, so it is replaced.
  def self.reset_timekeeping!(owner_state, env)
    TimekeepingDatabaseReset.reset!(owner_state, env:)
  rescue PG::Error
    raise BootError, "timekeeping database could not be reset", cause: nil
  end

  def self.kill_group(group)
    Process.kill("KILL", -group)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  private_class_method :monolith_database_name, :timekeeping_database_name, :free_port,
                       :clear_leftovers!, :prepare_timekeeping!, :reset_timekeeping!

  def initialize(root:, env:, credentials:, ports:)
    @root = root
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

  def boot!
    @log = Tempfile.new(["timekeeping-demo-runtime", ".log"])
    spawn_env, argv, options = self.class.launch(root: @root, env: @env, credentials:, ports: @ports)
    @launcher = Process.spawn(spawn_env, *argv, **options, out: @log.path, err: [:child, :out])
    wait_until_ready
  rescue StandardError
    stop!
    raise
  end

  # Sends TERM to the launcher, whose supervisor then stops its apps; waits
  # past the supervisor's own grace period; then kills every recorded group
  # still alive. Safe to call again: a call after a full stop does nothing.
  def stop!
    return if @stopped

    signal_launcher("TERM")
    deadline = monotonic_now + TimekeepingDemo::Supervisor::STOP_GRACE_SECONDS + STOP_MARGIN_SECONDS
    loop do
      # Reaping first: an unreaped launcher stays in its group and keeps it alive.
      reap_launcher(Process::WNOHANG)
      break if process_groups.none? { |group| self.class.group_alive?(group) }
      break if monotonic_now > deadline

      sleep POLL_SECONDS
    end
    process_groups.each { |group| self.class.kill_group(group) if self.class.group_alive?(group) }
    reap_launcher(0)
    @log&.close!
    @stopped = true
  end

  def inspect
    "#<#{self.class.name} monolith_url=#{monolith_url} timekeeping_url=#{timekeeping_url} [credentials hidden]>"
  end
  alias_method :to_s, :inspect

  private

    def wait_until_ready
      deadline = monotonic_now + BOOT_TIMEOUT_SECONDS
      loop do
        raise BootError, "the timekeeping-demo launcher exited before the runtime was ready" if reap_launcher(Process::WNOHANG)

        waiting = { "monolith" => monolith_ready?, "timekeeping" => timekeeping_ready? }.reject { |_app, ready| ready }.keys
        return if waiting.empty?
        raise BootError, "#{waiting.join(' and ')} not ready within #{BOOT_TIMEOUT_SECONDS} s" if monotonic_now > deadline

        sleep POLL_SECONDS
      end
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
  # Registered after the cleaner and owner-state hooks (see the require above):
  # the monolith is emptied and the owner state put back before the runtime
  # starts. The live-group check comes first, so a surviving worker from an
  # earlier run is never running while rows are deleted.
  config.before(:each, :integrated_runtime) do
    root = Rails.root.to_s
    IntegratedRuntime.refuse_if_running!(root:)
    IntegratedRuntime.clean_monolith!
    @integrated_runtime = IntegratedRuntime.start(root:, env: ENV.to_h)
  end

  # A plain after hook runs before every append_after cleaner, so the runtime's
  # workers and relay are stopped before any reset.
  config.after(:each, :integrated_runtime) do
    @integrated_runtime&.stop!
    IntegratedRuntime.clean_monolith!
  end
end

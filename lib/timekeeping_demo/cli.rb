# frozen_string_literal: true

require "fileutils"
require "json"
require "uri"

module TimekeepingDemo
  # The `bin/timekeeping-demo` command. `up` takes the caller's complete
  # credential set or makes a fresh one, plans the processes from
  # Procfile.timekeeping, prepares both databases, records the running
  # versions and hands the processes to the supervisor. `regression` runs the
  # regression specs in every ownership state through TimekeepingDemo::Regression.
  module CLI
    EX_OK = 0
    EX_FAILURE = 1
    EX_USAGE = 64
    EX_CONFIG = 78

    PROCFILE = "Procfile.timekeeping"
    DEFAULT_STATE_DIR = "tmp/timekeeping-demo"
    VERSIONS_FILE = "versions.json"
    PROCESS_GROUPS_FILE = "process_groups"
    DEFAULT_PORTS = { monolith: 3000, timekeeping: 3100 }.freeze
    PORT_KEYS = { monolith: "MONOLITH_PORT", timekeeping: "TIMEKEEPING_PORT" }.freeze
    USAGE = "usage: bin/timekeeping-demo up|regression"
    TEST_DATABASE_SUFFIX = "_test"
    # Ctrl-C in the terminal, or a TERM from whoever started the demo.
    STOP_SIGNALS = %w[INT TERM].freeze

    module_function

    # Answers the process exit status. A relative state_dir is read from root.
    # Without a supervisor, the default one records every process group it
    # starts in state_dir's PROCESS_GROUPS_FILE, so a caller can still find and
    # stop the applications after this launcher itself was killed.
    # `regression` is dispatched before any supervisor is built, so it never
    # creates state_dir; without a regression_runner it spawns rspec from root.
    def run(argv, root:, supervisor: nil, state_dir: DEFAULT_STATE_DIR, caller_env: ENV.to_h,
            regression_runner: nil)
      case argv
      in ["regression"]
        regression(root:, caller_env:, runner: regression_runner)
      in ["up"]
        start(root:, supervisor:, state_dir:, caller_env:)
      else
        usage_error
      end
    end

    def start(root:, supervisor:, state_dir:, caller_env:)
      state_dir = File.expand_path(state_dir, root)
      supervisor ||= default_supervisor(state_dir)
      up(root:, supervisor:, state_dir:, caller_env:)
    rescue ConfigurationError, Supervisor::ProcessFailed, VersionRecord::GitError => e
      warn "timekeeping-demo: #{e.message}"
      e.is_a?(ConfigurationError) ? EX_CONFIG : EX_FAILURE
    end

    # A caller that holds a complete credential set, such as a test that must
    # authenticate to the started apps, gets it used; any other set is
    # replaced whole, so supplied and generated values are never mixed.
    def up(root:, supervisor:, state_dir:, caller_env:)
      credentials = Credentials.from_env(caller_env) || Credentials.generate
      specs = RuntimePlan.build(root:, procfile: File.read(File.join(root, PROCFILE)), caller_env:,
                                credentials:, ports: ports(caller_env))
      supervisor.prepare(specs)
      write_versions(state_dir, VersionRecord.capture(root:))
      supervisor.run(specs, stop_signals: STOP_SIGNALS)
      EX_OK
    end

    def regression(root:, caller_env:, runner:)
      Regression.run(runner: runner || default_regression_runner(root:, caller_env:))
    rescue ConfigurationError => e
      warn "timekeeping-demo: #{e.message}"
      EX_CONFIG
    end

    # Active Record reads the database from the URL path and lets a `database`
    # query parameter override it; libpq reads a `dbname` parameter. Each name
    # any of them could open must end in _test.
    def require_test_database_url!(url)
      return if url.strip.empty?

      uri = URI.parse(url)
      query = URI.decode_www_form(uri.query.to_s).to_h
      names = [URI.decode_www_form_component(uri.path.to_s.delete_prefix("/")), query["dbname"], query["database"]]
      unsafe = names.compact.reject { |name| name.empty? || name.end_with?(TEST_DATABASE_SUFFIX) }
      return if unsafe.empty?

      raise ConfigurationError, "#{RuntimePlan::MONOLITH_DATABASE_URL} names #{unsafe.join(', ')}; " \
                                "the regression specs empty their database, so it must end in #{TEST_DATABASE_SUFFIX}"
    rescue URI::InvalidURIError, ArgumentError
      raise ConfigurationError, "#{RuntimePlan::MONOLITH_DATABASE_URL} is not a valid database URL"
    end

    # The child's values win over the caller's; a nil value makes system drop
    # an inherited key. The argv array is passed as separate arguments, so no
    # shell ever reads a spec path. The result is system's own: true, false,
    # or nil when rspec could not start or was killed.
    #
    # Every child empties its database at suite start, so a caller
    # DATABASE_URL must name a _test database, checked here before any child
    # can start. Without one, the key is set to "" (which config/application.rb
    # reads as unset) so that dotenv cannot fill it from a local .env.
    def default_regression_runner(root:, caller_env:)
      database_url = caller_env.fetch(RuntimePlan::MONOLITH_DATABASE_URL, "")
      require_test_database_url!(database_url)
      child_caller_env = caller_env.merge(RuntimePlan::MONOLITH_DATABASE_URL => database_url)
      lambda do |env:, argv:|
        system(child_caller_env.merge(env), "bundle", "exec", "rspec", *argv, chdir: root)
      end
    end

    def default_supervisor(state_dir)
      FileUtils.mkdir_p(state_dir)
      Supervisor.new(groups_path: File.join(state_dir, PROCESS_GROUPS_FILE))
    end

    def ports(caller_env)
      DEFAULT_PORTS.to_h do |app, default|
        value = caller_env.fetch(PORT_KEYS.fetch(app), default.to_s)
        port = Integer(value, 10, exception: false)
        raise ConfigurationError, "#{PORT_KEYS.fetch(app)} must be a port number" unless port&.between?(1, 65_535)

        [app, port]
      end
    end

    # The record names only commits, trees and digests, never a key or URL.
    def write_versions(state_dir, record)
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, VERSIONS_FILE), "#{JSON.pretty_generate(record)}\n")
    end

    def usage_error
      warn USAGE
      EX_USAGE
    end
  end
end

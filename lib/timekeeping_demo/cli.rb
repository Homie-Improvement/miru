# frozen_string_literal: true

require "fileutils"
require "json"

module TimekeepingDemo
  # The `bin/timekeeping-demo` command. `up` takes the caller's complete
  # credential set or makes a fresh one, plans
  # the processes from Procfile.timekeeping, prepares both databases, records
  # the running versions and hands the processes to the supervisor.
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
    USAGE = "usage: bin/timekeeping-demo up"
    # Ctrl-C in the terminal, or a TERM from whoever started the demo.
    STOP_SIGNALS = %w[INT TERM].freeze

    module_function

    # Answers the process exit status. A relative state_dir is read from root.
    # Without a supervisor, the default one records every process group it
    # starts in state_dir's PROCESS_GROUPS_FILE, so a caller can still find and
    # stop the applications after this launcher itself was killed.
    def run(argv, root:, supervisor: nil, state_dir: DEFAULT_STATE_DIR, caller_env: ENV.to_h)
      return usage_error unless argv == ["up"]

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

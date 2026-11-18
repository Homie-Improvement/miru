# frozen_string_literal: true

require "fileutils"
require "json"

module TimekeepingDemo
  # The `bin/timekeeping-demo` command. `up` makes fresh credentials, plans
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
    DEFAULT_PORTS = { monolith: 3000, timekeeping: 3100 }.freeze
    PORT_KEYS = { monolith: "MONOLITH_PORT", timekeeping: "TIMEKEEPING_PORT" }.freeze
    USAGE = "usage: bin/timekeeping-demo up"
    # Ctrl-C in the terminal, or a TERM from whoever started the demo.
    STOP_SIGNALS = %w[INT TERM].freeze

    module_function

    # Answers the process exit status. A relative state_dir is read from root.
    def run(argv, root:, supervisor: Supervisor.new, state_dir: DEFAULT_STATE_DIR, caller_env: ENV.to_h)
      return usage_error unless argv == ["up"]

      up(root:, supervisor:, state_dir: File.expand_path(state_dir, root), caller_env:)
    rescue ConfigurationError, Supervisor::ProcessFailed, VersionRecord::GitError => e
      warn "timekeeping-demo: #{e.message}"
      e.is_a?(ConfigurationError) ? EX_CONFIG : EX_FAILURE
    end

    def up(root:, supervisor:, state_dir:, caller_env:)
      specs = RuntimePlan.build(root:, procfile: File.read(File.join(root, PROCFILE)), caller_env:,
                                credentials: Credentials.generate, ports: ports(caller_env))
      supervisor.prepare(specs)
      write_versions(state_dir, VersionRecord.capture(root:))
      supervisor.run(specs, stop_signals: STOP_SIGNALS)
      EX_OK
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

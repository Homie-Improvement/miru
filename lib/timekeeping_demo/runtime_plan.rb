# frozen_string_literal: true

require "etc"
require "shellwords"
require "uri"

module TimekeepingDemo
  # Turns Procfile.timekeeping into the processes of the local demo runtime:
  # each one's arguments, absolute working directory and complete environment.
  # Nothing here starts a process or reads the real environment, so every rule
  # about which keys reach which application can be tested directly.
  module RuntimePlan
    PROCFILE_LINE = /\A(?<name>[a-z][a-z0-9_]*):\s*(?<command>\S.*)\z/
    PLACEHOLDER = /\$\{(?<key>[^}]*)\}/

    # Copied from the caller into every process so Ruby and Bundler still work.
    TOOLCHAIN_KEYS = %w[PATH HOME LANG GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_APP_CONFIG].freeze
    DEFAULT_RAILS_ENV = "development"
    LOOPBACK = "127.0.0.1"

    TIMEKEEPING_DATABASE_URL = "TIMEKEEPING_DATABASE_URL"
    MONOLITH_DATABASE_URL = "DATABASE_URL"
    MONOLITH_DATABASE_USER = "DB_USER"

    # directory: relative to the checkout root.
    # copied: caller keys passed on only when the caller sets them.
    # always_set: caller keys passed on, or set to "" when the caller has none.
    # blanked: keys always set to "", whatever the caller holds.
    #   The monolith loads dotenv-rails, which fills only absent keys, so a set
    #   key keeps a local .env from adding a database credential after the
    #   check in this module. Timekeeping loads no .env.
    # required: caller keys the application cannot start without.
    APPLICATIONS = {
      monolith: {
        directory: ".",
        copied: %w[DB_HOST DB_POOL],
        always_set: [MONOLITH_DATABASE_URL, MONOLITH_DATABASE_USER, "DB_PASS"],
        blanked: [TIMEKEEPING_DATABASE_URL],
        required: []
      },
      timekeeping: {
        directory: "timekeeping",
        copied: [],
        always_set: [],
        blanked: [],
        required: [TIMEKEEPING_DATABASE_URL]
      }
    }.freeze

    module_function

    # Answers one ProcessSpec per Procfile line, or raises ConfigurationError.
    # login_user is the database user libpq picks when a connection names none.
    def build(root:, procfile:, caller_env:, credentials:, ports:, login_user: default_login_user)
      ensure_separate_database_users!(caller_env, login_user)
      placeholders = { "MONOLITH_PORT" => ports.fetch(:monolith).to_s,
                       "TIMEKEEPING_PORT" => ports.fetch(:timekeeping).to_s }

      procfile_entries(procfile).map do |name, command|
        app = application_of(name)
        directory = File.expand_path(APPLICATIONS.fetch(app).fetch(:directory), root)
        ProcessSpec.new(name:, app:, argv: arguments(command, placeholders), chdir: directory,
                        env: environment(app, directory, caller_env, credentials, ports))
      end
    end

    def procfile_entries(procfile)
      entries = procfile.each_line.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.map do |line|
        match = PROCFILE_LINE.match(line)
        raise ConfigurationError, "Procfile line is not `name: command`: #{line}" unless match

        [match[:name], match[:command]]
      end
      duplicates = entries.map(&:first).tally.select { |_name, count| count > 1 }.keys
      raise ConfigurationError, "Procfile names a process twice: #{duplicates.join(', ')}" if duplicates.any?

      entries
    end

    def application_of(name)
      app = APPLICATIONS.keys.find { |candidate| name.start_with?("#{candidate}_") }
      return app if app

      raise ConfigurationError,
            "Process #{name} must start with the application it belongs to: #{APPLICATIONS.keys.join('_ or ')}_"
    end

    def arguments(command, placeholders)
      Shellwords.split(command).map do |argument|
        argument.gsub(PLACEHOLDER) do
          key = Regexp.last_match[:key]
          placeholders.fetch(key) do
            raise ConfigurationError, "Unknown placeholder ${#{key}}; only #{placeholders.keys.join(', ')} are set"
          end
        end
      end
    end

    def environment(app, directory, caller_env, credentials, ports)
      settings = APPLICATIONS.fetch(app)
      env = caller_env.slice(*TOOLCHAIN_KEYS, *settings.fetch(:copied))
      settings.fetch(:always_set).each { |key| env[key] = caller_env.fetch(key, "") }
      settings.fetch(:blanked).each { |key| env[key] = "" }
      env.merge(
        "RAILS_ENV" => caller_env.fetch("RAILS_ENV", DEFAULT_RAILS_ENV),
        "BUNDLE_GEMFILE" => File.join(directory, "Gemfile")
      ).merge(own_keys(app, caller_env, credentials, ports))
    end

    # The section 11.2 keys each application reads, and nothing the other
    # application holds: the private key never reaches Timekeeping.
    def own_keys(app, caller_env, credentials, ports)
      monolith_url = "http://#{LOOPBACK}:#{ports.fetch(:monolith)}"
      case app
      when :monolith
        {
          "TIMEKEEPING_TOKEN_PRIVATE_KEY" => credentials.private_key_pem,
          "TIMEKEEPING_SERVICE_TOKEN" => credentials.service_token,
          "TIMEKEEPING_BASE_URL" => "http://#{LOOPBACK}:#{ports.fetch(:timekeeping)}",
          "TIMEKEEPING_PROJECTION_URL" => monolith_url
        }
      when :timekeeping
        {
          TIMEKEEPING_DATABASE_URL => caller_env.fetch(TIMEKEEPING_DATABASE_URL),
          "TIMEKEEPING_TOKEN_PUBLIC_KEY" => credentials.public_key_pem,
          "TIMEKEEPING_SERVICE_TOKEN" => credentials.service_token,
          "MONOLITH_REFERENCE_URL" => monolith_url,
          "MONOLITH_SNAPSHOT_URL" => monolith_url
        }
      end
    end

    def ensure_separate_database_users!(caller_env, login_user)
      APPLICATIONS.each_value do |settings|
        settings.fetch(:required).each do |key|
          raise ConfigurationError, "#{key} must be set: the demo has no other database to give" if blank?(caller_env[key])
        end
      end

      timekeeping_user = url_user(caller_env.fetch(TIMEKEEPING_DATABASE_URL)) || login_user
      monolith_user = monolith_database_user(caller_env) || login_user
      return unless timekeeping_user == monolith_user

      raise ConfigurationError,
            "#{TIMEKEEPING_DATABASE_URL} connects as the monolith's database user; give Timekeeping its own user"
    end

    # The user config/database.yml connects as: the user in DATABASE_URL when
    # it names one, otherwise DB_USER; nil leaves it to libpq.
    def monolith_database_user(caller_env)
      url = caller_env[MONOLITH_DATABASE_URL]
      from_url = url_user(url) unless blank?(url)
      from_url || caller_env[MONOLITH_DATABASE_USER].then { |user| blank?(user) ? nil : user }
    end

    def url_user(url)
      user = URI.parse(url).user
      blank?(user) ? nil : URI.decode_uri_component(user)
    rescue URI::InvalidURIError
      raise ConfigurationError, "A database URL could not be parsed"
    end

    def blank?(value)
      value.nil? || value.strip.empty?
    end

    def default_login_user
      Etc.getpwuid(Process.uid)&.name || Etc.getlogin
    end
  end
end

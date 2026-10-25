# frozen_string_literal: true

require "rails_helper"
require "open3"

# Boots the service in production, in a child process whose environment holds
# only the service's four keys, RAILS_ENV and the variables Ruby needs to find
# its gems. A setting the app read from anywhere else would fail this boot.
RSpec.describe "Timekeeping service boot" do
  app_root = File.expand_path("..", __dir__)
  ruby_toolchain_keys = %w[PATH HOME GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_APP_CONFIG].freeze
  # Prints the database the app is configured for and the one it reached, then
  # sends one request through the full middleware stack.
  probe = <<~RUBY
    config = ActiveRecord::Base.connection_db_config
    reached = ActiveRecord::Base.connection.select_value("SELECT current_database()")
    status, = Rails.application.call(Rack::MockRequest.env_for("/"))
    puts [config.name, config.database, reached, status].join(" ")
  RUBY

  def boot_in_production(app_root, toolchain_keys, probe, extra_env = {})
    env = ENV.to_h.slice(*toolchain_keys).merge(
      "RAILS_ENV" => "production",
      Timekeeping::Environment::DATABASE_URL => Timekeeping::Environment.database_url,
      Timekeeping::Environment::TOKEN_PUBLIC_KEY => OpenSSL::PKey::RSA.generate(2048).public_key.to_pem,
      Timekeeping::Environment::SERVICE_TOKEN => SecureRandom.hex(32),
      Timekeeping::Environment::MONOLITH_REFERENCE_URL => "http://monolith.invalid"
    ).merge(extra_env)

    Open3.capture2e(env, RbConfig.ruby, "bin/rails", "runner", probe, chdir: app_root, unsetenv_others: true)
  end

  let(:timekeeping_database) do
    ActiveRecord::Base.connection.select_value("SELECT current_database()")
  end

  it "boots in production from the four Timekeeping keys alone" do
    output, status = boot_in_production(app_root, ruby_toolchain_keys, probe)

    expect(status).to be_success, output
    expect(output.lines.last.split).to eq(["timekeeping", timekeeping_database, timekeeping_database, "404"])
  end

  it "ignores a DATABASE_URL in the same environment" do
    output, status = boot_in_production(
      app_root, ruby_toolchain_keys, probe,
      "DATABASE_URL" => "postgres://monolith.invalid:5432/miru_web_production"
    )

    expect(status).to be_success, output
    expect(output.lines.last.split.take(3)).to eq(["timekeeping", timekeeping_database, timekeeping_database])
  end

  it "keeps no master key, credentials file or PEM in the app tree" do
    secret_files = Dir.glob(
      ["config/master.key", "config/credentials*", "config/credentials/**/*", "**/*.pem"],
      base: app_root
    ).reject { |path| path.start_with?("tmp/", "log/", "vendor/") }

    expect(secret_files).to be_empty
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/environments/production.rb" do
  # Stands in for Rails.application.config so loading the environment file records its
  # settings here instead of changing the real application's configuration.
  recording_options_class = Class.new do
    def initialize
      @values = {}
    end

    def method_missing(name, *args)
      key = name.to_s
      if key.end_with?("=")
        @values[key.chomp("=").to_sym] = args.first
      else
        @values.fetch(name) { @values[name] = self.class.new }
      end
    end
  end

  define_method(:load_production_config_with_empty_base_url) do |app_base_url|
    production_file = Rails.root.join("config/environments/production.rb").to_s
    recorded_config = recording_options_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { recorded_config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    original_app_base_url = ENV["APP_BASE_URL"]
    begin
      app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = app_base_url
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    ensure
      original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    end
    recorded_config
  end

  # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
  it "R1: an empty APP_BASE_URL makes production.rb use its default base URL for the mailer asset host and host authorization" do
    real_hosts = Rails.application.config.hosts.dup

    config = load_production_config_with_empty_base_url("")

    default_base_url = config.x.default_base_url
    expect(default_base_url).to be_a(String).and(start_with("https://"))
    expect(config.action_mailer.asset_host).to eq(default_base_url)
    expect(config.hosts).to include(URI.parse(default_base_url).host)
    expect(config.hosts).not_to include("")

    RSpec::Mocks.space.proxy_for(Rails).reset
    expect(Rails.application.config.hosts).to eq(real_hosts)
  end
end


RSpec.describe "config/environments/production.rb" do
  # Stands in for Rails.application.config so loading the environment file records its
  # settings here instead of changing the real application's configuration.
  recording_options_class = Class.new do
    def initialize
      @values = {}
    end

    def method_missing(name, *args)
      key = name.to_s
      if key.end_with?("=")
        @values[key.chomp("=").to_sym] = args.first
      else
        @values.fetch(name) { @values[name] = self.class.new }
      end
    end
  end

  # Resolved before any example stubs Rails.application, because Rails.root reads the
  # application's config and this example loads the file more than once.
  production_file = Rails.root.join("config/environments/production.rb").to_s

  define_method(:load_production_config_with_whitespace_base_url) do |app_base_url|
    recorded_config = recording_options_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { recorded_config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    original_app_base_url = ENV["APP_BASE_URL"]
    begin
      ENV["APP_BASE_URL"] = app_base_url
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    ensure
      original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    end
    recorded_config
  end

  # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
  it "R1: a whitespace-only APP_BASE_URL makes production.rb use its default base URL instead of the blank value" do
    ["  ", " \t\n "].each do |whitespace_value|
      config = load_production_config_with_whitespace_base_url(whitespace_value)

      default_base_url = config.x.default_base_url
      expect(default_base_url).to be_a(String).and(start_with("https://"))
      expect(config.action_mailer.asset_host).to eq(default_base_url)
      expect(config.hosts).to include(URI.parse(default_base_url).host)
      expect(config.hosts.map(&:to_s).map(&:strip)).not_to include("")
    end
  end
end


RSpec.describe "config/environments/production.rb" do
  # Stands in for Rails.application.config so loading the environment file records its
  # settings here instead of changing the real application's configuration.
  recording_options_class = Class.new do
    def initialize
      @values = {}
    end

    def method_missing(name, *args)
      key = name.to_s
      if key.end_with?("=")
        @values[key.chomp("=").to_sym] = args.first
      else
        @values.fetch(name) { @values[name] = self.class.new }
      end
    end
  end

  define_method(:load_production_config_with_set_base_url) do |app_base_url|
    production_file = Rails.root.join("config/environments/production.rb").to_s
    recorded_config = recording_options_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { recorded_config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    original_app_base_url = ENV["APP_BASE_URL"]
    begin
      ENV["APP_BASE_URL"] = app_base_url
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    ensure
      original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    end
    recorded_config
  end

  # A distinct value, unlike the default or the hard-coded production host, shows the file
  # reads APP_BASE_URL rather than always returning its default.
  it "R2: a non-blank APP_BASE_URL is still used by production.rb for the mailer asset host and host authorization" do
    config = load_production_config_with_set_base_url("https://boot-check.test")

    expect(config.action_mailer.asset_host).to eq("https://boot-check.test")
    expect(config.hosts).to include("boot-check.test")
    expect(config.x.default_base_url).not_to eq("https://boot-check.test")
  end
end


RSpec.describe "config/environments/production.rb" do
  # Stands in for Rails.application.config so loading the environment file records its
  # settings here instead of changing the real application's configuration.
  recording_options_class = Class.new do
    def initialize
      @values = {}
    end

    def method_missing(name, *args)
      key = name.to_s
      if key.end_with?("=")
        @values[key.chomp("=").to_sym] = args.first
      else
        @values.fetch(name) { @values[name] = self.class.new }
      end
    end
  end

  # Resolved before any example stubs Rails.application, because Rails.root reads the
  # application's config and this example loads the file more than once.
  production_file = Rails.root.join("config/environments/production.rb").to_s

  define_method(:load_production_config_for_unset_comparison) do |app_base_url|
    recorded_config = recording_options_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { recorded_config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    original_app_base_url = ENV["APP_BASE_URL"]
    begin
      app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = app_base_url
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    ensure
      original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    end
    recorded_config
  end

  # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
  it "R1: blank and unset APP_BASE_URL give production.rb the same mailer asset host" do
    unset_config = load_production_config_for_unset_comparison(nil)
    expect(unset_config.action_mailer.asset_host).to eq(unset_config.x.default_base_url)

    ["", "   "].each do |blank_value|
      blank_config = load_production_config_for_unset_comparison(blank_value)
      expect(blank_config.action_mailer.asset_host).to eq(unset_config.action_mailer.asset_host)
      expect(blank_config.hosts).to eq(unset_config.hosts)
    end
  end
end

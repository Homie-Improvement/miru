# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/environments/production.rb with an empty APP_BASE_URL" do
  around do |example|
    original = ENV["APP_BASE_URL"]
    ENV["APP_BASE_URL"] = ""
    example.run
  ensure
    original.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original
  end

  # Loads the real environment file against a stand-in application, so the shared
  # Rails.application.config is never changed by this spec.
  def load_production_config_for_empty_case
    production_file = Rails.root.join("config/environments/production.rb").to_s
    recorder_class = Class.new do
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

      def respond_to_missing?(*)
        true
      end
    end
    config = recorder_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    RSpec::Mocks.with_temporary_scope do
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    end
    config
  end

  it "R1 production.rb uses its default base URL when APP_BASE_URL is an empty string" do
    config = load_production_config_for_empty_case
    default_base_url = config.x.default_base_url

    # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
    expect(default_base_url).to be_a(String)
    expect(config.action_mailer.asset_host).to eq(default_base_url)
    expect(config.hosts).to include(URI.parse(default_base_url).host)
  end
end

RSpec.describe "config/environments/production.rb with a whitespace APP_BASE_URL" do
  around do |example|
    original = ENV["APP_BASE_URL"]
    ENV["APP_BASE_URL"] = "  "
    example.run
  ensure
    original.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original
  end

  # Loads the real environment file against a stand-in application, so the shared
  # Rails.application.config is never changed by this spec.
  def load_production_config_for_whitespace_case
    production_file = Rails.root.join("config/environments/production.rb").to_s
    recorder_class = Class.new do
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

      def respond_to_missing?(*)
        true
      end
    end
    config = recorder_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    RSpec::Mocks.with_temporary_scope do
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    end
    config
  end

  it "R1 production.rb uses its default base URL when APP_BASE_URL is only whitespace" do
    config = load_production_config_for_whitespace_case
    default_base_url = config.x.default_base_url

    # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
    expect(default_base_url).to be_a(String)
    expect(config.action_mailer.asset_host).to eq(default_base_url)
    expect(config.hosts).to include(URI.parse(default_base_url).host)
  end
end

RSpec.describe "config/environments/production.rb with a non-blank APP_BASE_URL" do
  around do |example|
    original = ENV["APP_BASE_URL"]
    ENV["APP_BASE_URL"] = "https://boot-check.test"
    example.run
  ensure
    original.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original
  end

  # Loads the real environment file against a stand-in application, so the shared
  # Rails.application.config is never changed by this spec.
  def load_production_config_for_present_case
    production_file = Rails.root.join("config/environments/production.rb").to_s
    recorder_class = Class.new do
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

      def respond_to_missing?(*)
        true
      end
    end
    config = recorder_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    RSpec::Mocks.with_temporary_scope do
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    end
    config
  end

  it "R2 production.rb still uses a non-blank APP_BASE_URL" do
    config = load_production_config_for_present_case

    # A value distinct from the default and from the hard-coded host proves the file reads the input.
    expect(config.action_mailer.asset_host).to eq("https://boot-check.test")
    expect(config.hosts).to include("boot-check.test")
    expect(config.x.default_base_url).not_to eq("https://boot-check.test")
  end
end

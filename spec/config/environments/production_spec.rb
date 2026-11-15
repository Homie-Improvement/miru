# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/environments/production.rb" do
  # Records what the environment file sets, so loading it never changes the real application's config.
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

    def respond_to_missing?(*)
      true
    end
  end

  # Resolved before any stub, because Rails.root reads the real application's config.
  production_file = Rails.root.join("config/environments/production.rb").to_s

  around do |example|
    original = ENV["APP_BASE_URL"]
    example.run
  ensure
    original.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original
  end

  define_method(:load_production_config) do |app_base_url|
    app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = app_base_url
    recorded_config = recording_options_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { recorded_config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    RSpec::Mocks.with_temporary_scope do
      allow(Rails).to receive(:application).and_return(fake_app)
      load production_file
    end
    recorded_config
  end

  # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
  # A deployment tool can write a variable as tabs or a trailing newline; that is still blank.
  ["", "  ", "\t \n"].each do |blank_value|
    it "uses its default base URL when APP_BASE_URL is #{blank_value.inspect}" do
      config = load_production_config(blank_value)
      default_base_url = config.x.default_base_url

      expect(default_base_url).to be_a(String).and(start_with("https://"))
      expect(config.action_mailer.asset_host).to eq(default_base_url)
      expect(config.hosts).to include(URI.parse(default_base_url).host)
      expect(config.hosts.map(&:to_s).map(&:strip)).not_to include("")
    end
  end

  it "gives a blank APP_BASE_URL the same mailer asset host and hosts as an unset one" do
    unset_config = load_production_config(nil)
    expect(unset_config.action_mailer.asset_host).to eq(unset_config.x.default_base_url)

    ["", "   "].each do |blank_value|
      blank_config = load_production_config(blank_value)
      expect(blank_config.action_mailer.asset_host).to eq(unset_config.action_mailer.asset_host)
      expect(blank_config.hosts).to eq(unset_config.hosts)
    end
  end

  it "leaves the real application's hosts unchanged after loading the file" do
    real_hosts = Rails.application.config.hosts.dup

    load_production_config("")

    expect(Rails.application.config.hosts).to eq(real_hosts)
  end

  # A value distinct from the default and from the hard-coded host proves the file reads the input.
  it "still uses a non-blank APP_BASE_URL" do
    config = load_production_config("https://boot-check.test")

    expect(config.action_mailer.asset_host).to eq("https://boot-check.test")
    expect(config.hosts).to include("boot-check.test")
    expect(config.x.default_base_url).not_to eq("https://boot-check.test")
  end
end

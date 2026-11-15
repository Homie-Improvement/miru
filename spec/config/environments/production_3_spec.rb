# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/environments/production.rb with a whitespace-only APP_BASE_URL" do
  it "R1 falls back to the default base URL when APP_BASE_URL holds only tabs, spaces and newlines" do
    # Resolved before the stub, because Rails.root reads the real application's config.
    production_file = Rails.root.join("config/environments/production.rb").to_s

    # Records what the environment file sets, so the real Rails config is never changed.
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

    fake_config = recorder_class.new
    fake_app = Object.new
    fake_app.define_singleton_method(:config) { fake_config }
    fake_app.define_singleton_method(:configure) { |&block| instance_eval(&block) }

    original_app_base_url = ENV["APP_BASE_URL"]
    begin
      # A deployment tool can write a variable as tabs or a trailing newline; that is still blank.
      ENV["APP_BASE_URL"] = "\t \n"
      allow(Rails).to receive(:application).and_return(fake_app)

      load production_file

      default_base_url = fake_config.x.default_base_url
      # "With APP_BASE_URL set to an empty or whitespace string, config/environments/production.rb uses its default base URL instead of the blank value."
      expect(fake_config.action_mailer.asset_host).to eq(default_base_url)
      expect(fake_config.hosts).to include(URI.parse(default_base_url).host)
    ensure
      if original_app_base_url.nil?
        ENV.delete("APP_BASE_URL")
      else
        ENV["APP_BASE_URL"] = original_app_base_url
      end
    end
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  describe ".pin!" do
    it "pins full_host to the fixed string rather than a callable that reads the request" do
      described_class.pin!("http://example.com")

      expect(OmniAuth.config.full_host).to eq("http://example.com")
      expect(OmniAuth.config.full_host).not_to respond_to(:call)
    end
  end

  describe "the initializer at boot" do
    it "declares the required default base URL for the test environment" do
      expect(Rails.configuration.x.default_base_url).to eq("http://example.com")
    end

    # A String, not a callable, means nothing on the pin path can read the request's headers.
    it "pins full_host to the environment's declared base URL as a fixed string when APP_BASE_URL is unset" do
      ENV.delete("APP_BASE_URL")
      OmniAuth.config.full_host = nil

      load initializer_path

      expect(OmniAuth.config.full_host).to be_a(String)
      expect(OmniAuth.config.full_host).to eq(Rails.configuration.x.default_base_url)
    end

    # The test environment declares the same host the specs expect, so this swaps in a
    # distinct value to show the initializer reads the setting rather than a literal.
    it "takes the fallback from config.x.default_base_url rather than a fixed value" do
      original_default_base_url = Rails.configuration.x.default_base_url
      ENV.delete("APP_BASE_URL")
      Rails.configuration.x.default_base_url = "https://boot-check.test"

      load initializer_path

      expect(OmniAuth.config.full_host).to eq("https://boot-check.test")
    ensure
      Rails.configuration.x.default_base_url = original_default_base_url
    end

    # A malformed value must stop boot: a relative or hostless full_host would let OmniAuth
    # fill in request-derived parts.
    it "refuses to boot on an APP_BASE_URL with no scheme instead of leaving full_host to the request" do
      ENV["APP_BASE_URL"] = "example.com"
      OmniAuth.config.full_host = nil

      expect { load initializer_path }.to raise_error(AppBaseUrl::InvalidBaseUrl)
    end
  end
end

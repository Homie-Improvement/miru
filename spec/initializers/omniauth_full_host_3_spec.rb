# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/initializers/omniauth_full_host.rb boot refusal" do
  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset,
  # and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  # A malformed value must stop boot: a relative or hostless full_host would let OmniAuth fill in request-derived parts.
  it "refuses to boot on an APP_BASE_URL with no scheme instead of leaving full_host to the request" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    begin
      ENV["APP_BASE_URL"] = "example.com"
      OmniAuth.config.full_host = nil

      expect {
        load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
      }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    ensure
      ENV["APP_BASE_URL"] = original_app_base_url
      OmniAuth.config.full_host = original_full_host
    end
  end
end

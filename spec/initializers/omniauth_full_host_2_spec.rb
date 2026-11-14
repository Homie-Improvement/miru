# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OmniauthFullHost.resolve with APP_BASE_URL unset" do
  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset, and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  it "uses the per-environment fallback when APP_BASE_URL is nil, empty or whitespace" do
    [nil, "", "   "].each do |unset_value|
      expect(OmniauthFullHost.resolve(app_base_url: unset_value, fallback: "http://example.com"))
        .to eq("http://example.com")
    end
  end
end

RSpec.describe "OmniauthFullHost.resolve with APP_BASE_URL set" do
  it "keeps a non-blank APP_BASE_URL ahead of the fallback and drops its trailing slash" do
    expect(OmniauthFullHost.resolve(app_base_url: "https://app.miru.so", fallback: "http://example.com"))
      .to eq("https://app.miru.so")
    expect(OmniauthFullHost.resolve(app_base_url: "https://app.miru.so/", fallback: "http://example.com"))
      .to eq("https://app.miru.so")
  end
end

RSpec.describe "OmniauthFullHost.resolve with no base URL at all" do
  # The per-environment value is required: a missing one must not leave OmniAuth
  # building the host from the request.
  it "refuses to resolve when both APP_BASE_URL and the required fallback are missing or blank" do
    [nil, "", "  "].each do |missing_fallback|
      expect { OmniauthFullHost.resolve(app_base_url: nil, fallback: missing_fallback) }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end
  end
end

RSpec.describe "OmniauthFullHost.resolve with a malformed base URL" do
  it "refuses a base URL that is not an absolute http or https URL with a host" do
    ["example.com", "ftp://example.com", "http://"].each do |malformed|
      expect { OmniauthFullHost.resolve(app_base_url: malformed, fallback: "http://example.com") }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
      expect { OmniauthFullHost.resolve(app_base_url: nil, fallback: malformed) }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end
  end
end

RSpec.describe "OmniauthFullHost.pin!" do
  around do |example|
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    OmniAuth.config.full_host = original_full_host
  end

  it "pins full_host to the fixed string rather than a callable that reads the request" do
    OmniauthFullHost.pin!("http://example.com")

    expect(OmniAuth.config.full_host).to eq("http://example.com")
    expect(OmniAuth.config.full_host).not_to respond_to(:call)
  end
end

RSpec.describe "Per-environment default base URL" do
  it "declares the required default base URL for the test environment" do
    expect(Rails.configuration.x.default_base_url).to eq("http://example.com")
  end
end

RSpec.describe "OmniauthFullHost.resolve with a blank APP_BASE_URL" do
  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset,
  # and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  # An empty or whitespace APP_BASE_URL must not pin full_host to an empty host.
  it "treats a whitespace-only APP_BASE_URL as unset and pins the per-environment value" do
    expect(OmniauthFullHost.resolve(app_base_url: "   ", fallback: "http://example.com")).to eq("http://example.com")
    expect(OmniauthFullHost.resolve(app_base_url: "", fallback: "http://example.com")).to eq("http://example.com")
  end
end

RSpec.describe "OmniauthFullHost.resolve with no usable per-environment value" do
  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset,
  # and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  # "Required" means a missing value fails loudly rather than falling back to the request's Host header.
  it "raises when APP_BASE_URL is unset and the per-environment value is missing, blank or hostless" do
    [nil, "", "http://", "ftp://example.com"].each do |fallback|
      expect {
        OmniauthFullHost.resolve(app_base_url: nil, fallback:)
      }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end
  end
end

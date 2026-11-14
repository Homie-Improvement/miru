require "rails_helper"

RSpec.describe "OmniauthFullHost.resolve rejects unusable base URLs" do
  # A required value that silently fell back would leave OmniAuth building callbacks
  # from the request's Host header, so every unusable value must raise instead.
  it "refuses a missing, blank or malformed base URL instead of leaving the host to the request" do
    [nil, "", "   "].each do |fallback|
      expect { OmniauthFullHost.resolve(app_base_url: nil, fallback:) }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end

    ["example.com", "ftp://example.com", "http://"].each do |malformed|
      expect { OmniauthFullHost.resolve(app_base_url: malformed, fallback: "http://example.com") }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
      expect { OmniauthFullHost.resolve(app_base_url: nil, fallback: malformed) }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end
  end
end

require "rails_helper"

RSpec.describe "OmniAuth full host initializer with APP_BASE_URL unset" do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    ENV.delete("APP_BASE_URL")
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset, and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  # A String, not a callable, means nothing on the pin path can read the request's headers.
  it "pins full_host to the environment's declared base URL as a fixed string when APP_BASE_URL is unset" do
    OmniAuth.config.full_host = nil

    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s

    expect(Rails.configuration.x.default_base_url).to eq("http://example.com")
    expect(OmniAuth.config.full_host).to be_a(String)
    expect(OmniAuth.config.full_host).to eq(Rails.configuration.x.default_base_url)
  end
end

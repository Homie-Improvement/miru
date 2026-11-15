# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AppBaseUrl" do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "current falls back to the swapped config.x.default_base_url when APP_BASE_URL is unset, empty or whitespace" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    [nil, "", "   "].each do |unset_value|
      unset_value.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = unset_value

      expect(AppBaseUrl.current).to eq("https://boot-check.test")
    end
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe "AppBaseUrl" do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "current prefers a set APP_BASE_URL over the setting, drops its trailing slash and re-reads it on every call" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    ENV["APP_BASE_URL"] = "https://app.miru.so/"
    expect(AppBaseUrl.current).to eq("https://app.miru.so")

    ENV["APP_BASE_URL"] = "https://second.miru.test"
    expect(AppBaseUrl.current).to eq("https://second.miru.test")
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe "AppBaseUrl" do
  it "resolve refuses a base URL that is not an absolute http or https URL with a host" do
    ["example.com", "ftp://example.com", "http://"].each do |malformed|
      expect { AppBaseUrl.resolve(app_base_url: malformed, fallback: "http://example.com") }
        .to raise_error(AppBaseUrl::InvalidBaseUrl)
      expect { AppBaseUrl.resolve(app_base_url: nil, fallback: malformed) }
        .to raise_error(AppBaseUrl::InvalidBaseUrl)
    end
    expect { AppBaseUrl.resolve(app_base_url: nil, fallback: "  ") }
      .to raise_error(AppBaseUrl::InvalidBaseUrl)
  end
end

RSpec.describe AppBaseUrl do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "resolve picks a set APP_BASE_URL, else the per-environment fallback, without trailing slashes" do
    expect(described_class.resolve(app_base_url: "https://app.miru.so//", fallback: "https://boot-check.test"))
      .to eq("https://app.miru.so")
    expect(described_class.resolve(app_base_url: nil, fallback: "https://boot-check.test/"))
      .to eq("https://boot-check.test")
    expect(described_class.resolve(app_base_url: "", fallback: "https://boot-check.test"))
      .to eq("https://boot-check.test")
  end
end

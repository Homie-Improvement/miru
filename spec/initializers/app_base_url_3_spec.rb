# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AppBaseUrl" do
  # Acceptance: each reader "reads the one per-environment base URL (APP_BASE_URL, else
  # config.x.default_base_url)". An ENV.fetch-style read would keep "   " and build broken links.
  it "treats a whitespace-only APP_BASE_URL as unset instead of returning it as the base URL" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV["APP_BASE_URL"] = "   "
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    expect(AppBaseUrl.current).to eq("https://boot-check.test")
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe "AppBaseUrl" do
  # A value cached at boot would ignore the later change, so readers would keep
  # disagreeing with "APP_BASE_URL, else config.x.default_base_url" as it stands now.
  it "follows APP_BASE_URL being set and then removed after boot rather than a value cached earlier" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    ENV["APP_BASE_URL"] = "https://app.miru.so"
    expect(AppBaseUrl.current).to eq("https://app.miru.so")

    ENV.delete("APP_BASE_URL")
    expect(AppBaseUrl.current).to eq("https://boot-check.test")
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe "AppBaseUrl" do
  # "example.com" would turn every email link and the QuickBooks redirect into a relative path.
  it "refuses an APP_BASE_URL with no scheme instead of handing readers a relative base" do
    original_app_base_url = ENV["APP_BASE_URL"]
    ENV["APP_BASE_URL"] = "example.com"

    expect { AppBaseUrl.current }.to raise_error(AppBaseUrl::InvalidBaseUrl)
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
  end
end

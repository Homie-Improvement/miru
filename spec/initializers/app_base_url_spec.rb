require "rails_helper"

RSpec.describe "AppBaseUrl" do
  # A relative or schemeless base URL would put a broken or attacker-shaped link into
  # OAuth redirects and client emails, so every reader must get an error instead.
  it "AppBaseUrl.current refuses an APP_BASE_URL that is not an absolute http or https URL with a host" do
    original_app_base_url = ENV["APP_BASE_URL"]
    ["example.com", "ftp://example.com", "http://", "javascript:alert(1)"].each do |malformed|
      ENV["APP_BASE_URL"] = malformed
      expect { AppBaseUrl.current }.to raise_error(AppBaseUrl::InvalidBaseUrl)
    end
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
  end
end

require "rails_helper"

RSpec.describe "AppBaseUrl" do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "AppBaseUrl.current treats a blank or whitespace APP_BASE_URL as unset and uses config.x.default_base_url" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    ["", "   "].each do |blank|
      ENV["APP_BASE_URL"] = blank
      expect(AppBaseUrl.current).to eq("https://boot-check.test")
    end
  ensure
    Rails.configuration.x.default_base_url = original_default_base_url
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
  end
end

RSpec.describe AppBaseUrl do
  # The per-environment value is required: a missing one must not leave readers
  # building links from the request.
  it "resolve refuses when both APP_BASE_URL and the required fallback are missing or blank" do
    [nil, "", "   "].each do |missing_fallback|
      expect { described_class.resolve(app_base_url: nil, fallback: missing_fallback) }
        .to raise_error(AppBaseUrl::InvalidBaseUrl)
    end
  end
end

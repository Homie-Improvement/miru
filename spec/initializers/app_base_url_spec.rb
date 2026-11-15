# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppBaseUrl do
  describe ".current" do
    # The test environment declares http://example.com, which a hard-coded literal could also
    # produce, so these swap in a distinct value to show the setting is what gets read.
    # The .resolve examples stay outside this hook so the setting there differs from their fallback.
    around do |example|
      with_app_base_url(env: nil, default: "https://boot-check.test") { example.run }
    end
    # An ENV.fetch-style read would keep "   " and build broken links.
    it "AppBaseUrl.current treats a blank or whitespace APP_BASE_URL as unset and uses config.x.default_base_url" do
      [nil, "", "   "].each do |unset_value|
        unset_value.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = unset_value

        expect(described_class.current).to eq("https://boot-check.test")
      end
    end

    # A value cached at boot would ignore a later change to APP_BASE_URL.
    it "prefers a set APP_BASE_URL over the setting, drops its trailing slash and re-reads it on every call" do
      ENV["APP_BASE_URL"] = "https://app.miru.so/"
      expect(described_class.current).to eq("https://app.miru.so")

      ENV["APP_BASE_URL"] = "https://second.miru.test"
      expect(described_class.current).to eq("https://second.miru.test")

      ENV.delete("APP_BASE_URL")
      expect(described_class.current).to eq("https://boot-check.test")
    end

    # A relative or schemeless base URL would put a broken or attacker-shaped link into
    # OAuth redirects and client emails, so every reader must get an error instead.
    it "AppBaseUrl.current refuses an APP_BASE_URL that is not an absolute http or https URL with a host" do
      ["example.com", "ftp://example.com", "http://", "javascript:alert(1)"].each do |malformed|
        ENV["APP_BASE_URL"] = malformed
        expect { described_class.current }.to raise_error(AppBaseUrl::InvalidBaseUrl)
      end
    end
  end

  describe ".resolve" do
    it "resolve picks a set APP_BASE_URL, else the per-environment fallback, without trailing slashes" do
      expect(described_class.resolve(app_base_url: "https://app.miru.so//", fallback: "https://boot-check.test"))
        .to eq("https://app.miru.so")
      expect(described_class.resolve(app_base_url: nil, fallback: "https://boot-check.test/"))
        .to eq("https://boot-check.test")
      expect(described_class.resolve(app_base_url: "", fallback: "https://boot-check.test"))
        .to eq("https://boot-check.test")
    end

    # The per-environment value is required: a missing one must not leave readers
    # building links from the request.
    it "resolve refuses when both APP_BASE_URL and the required fallback are missing or blank" do
      [nil, "", "  ", "   "].each do |missing_fallback|
        expect { described_class.resolve(app_base_url: nil, fallback: missing_fallback) }
          .to raise_error(AppBaseUrl::InvalidBaseUrl)
      end
    end

    it "resolve refuses a base URL that is not an absolute http or https URL with a host" do
      ["example.com", "ftp://example.com", "http://"].each do |malformed|
        expect { described_class.resolve(app_base_url: malformed, fallback: "http://example.com") }
          .to raise_error(AppBaseUrl::InvalidBaseUrl)
        expect { described_class.resolve(app_base_url: nil, fallback: malformed) }
          .to raise_error(AppBaseUrl::InvalidBaseUrl)
      end
    end
  end
end

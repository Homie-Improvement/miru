# frozen_string_literal: true

require "rails_helper"

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
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
      with_app_base_url(env: nil, default: Rails.configuration.x.default_base_url) do
        OmniAuth.config.full_host = nil

        load initializer_path

        expect(OmniAuth.config.full_host).to be_a(String)
        expect(OmniAuth.config.full_host).to eq(Rails.configuration.x.default_base_url)
      end
    end

    # The test environment declares the same host the specs expect, so this swaps in a
    # distinct value to show the initializer reads the setting rather than a literal.
    it "takes the fallback from config.x.default_base_url rather than a fixed value" do
      with_app_base_url(env: nil, default: "https://boot-check.test") do
        load initializer_path

        expect(OmniAuth.config.full_host).to eq("https://boot-check.test")
      end
    end

    # A malformed value must stop boot: a relative or hostless full_host would let OmniAuth
    # fill in request-derived parts.
    it "refuses to boot on an APP_BASE_URL with no scheme instead of leaving full_host to the request" do
      with_app_base_url(env: "example.com", default: Rails.configuration.x.default_base_url) do
        OmniAuth.config.full_host = nil

        expect { load initializer_path }.to raise_error(AppBaseUrl::InvalidBaseUrl)
      end
    end
  end

  # Production forces SSL, so an http base URL there must stop boot; development and test keep
  # their plain-http local defaults.
  describe "the production https rule" do
    def stub_production_env_for_https_rule
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    end

    # A silent upgrade to https would hide the misconfiguration, so boot must raise and pin nothing.
    it "refuses to boot in production on an http APP_BASE_URL, leaving full_host unpinned" do
      stub_production_env_for_https_rule
      with_app_base_url(env: "http://app.miru.so", default: Rails.configuration.x.default_base_url) do
        OmniAuth.config.full_host = nil

        expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
        expect(OmniAuth.config.full_host).to be_nil
      end
    end

    # An unset APP_BASE_URL must not route around the rule through an http fallback.
    it "refuses to boot in production on an http fallback when APP_BASE_URL is unset" do
      stub_production_env_for_https_rule
      with_app_base_url(env: nil, default: "http://fallback-check.test") do
        OmniAuth.config.full_host = nil

        expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
        expect(OmniAuth.config.full_host).to be_nil
      end
    end

    it "boots in production on an https APP_BASE_URL and pins it without its trailing slash" do
      stub_production_env_for_https_rule
      with_app_base_url(env: "https://app.miru.so/", default: Rails.configuration.x.default_base_url) do
        OmniAuth.config.full_host = nil

        expect { load initializer_path }.not_to raise_error
        expect(OmniAuth.config.full_host).to eq("https://app.miru.so")
      end
    end

    it "still boots in the test environment on an http APP_BASE_URL" do
      with_app_base_url(env: "http://app.miru.so", default: Rails.configuration.x.default_base_url) do
        load initializer_path

        expect(OmniAuth.config.full_host).to eq("http://app.miru.so")
      end
    end

    # Letter case or padding must not become a way around the https rule.
    it "resolve with require_https refuses non-https base URLs from either source" do
      ["http://app.miru.so", "HTTP://app.miru.so", "  http://app.miru.so/  ", "ftp://app.miru.so"].each do |non_https|
        expect { described_class.resolve(app_base_url: non_https, fallback: "https://fallback.test", require_https: true) }
          .to raise_error(OmniauthFullHost::InvalidBaseUrl)
      end
      expect { described_class.resolve(app_base_url: nil, fallback: "http://example.com", require_https: true) }
        .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end

    it "resolve with require_https accepts https from either source" do
      expect(described_class.resolve(app_base_url: "https://app.miru.so", fallback: "http://example.com", require_https: true))
        .to eq("https://app.miru.so")
      expect(described_class.resolve(app_base_url: "https://app.miru.so/", fallback: "http://example.com", require_https: true))
        .to eq("https://app.miru.so")
      expect(described_class.resolve(app_base_url: "  ", fallback: "https://fallback.test/", require_https: true))
        .to eq("https://fallback.test")
    end

    it "resolve keeps accepting http base URLs when require_https is false or omitted" do
      expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com"))
        .to eq("http://app.miru.so")
      expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com", require_https: false))
        .to eq("http://app.miru.so")
      expect(described_class.resolve(app_base_url: nil, fallback: "http://localhost:3000", require_https: false))
        .to eq("http://localhost:3000")
    end

    # Boot errors reach deploy logs, and APP_BASE_URL is stored as a deploy secret.
    it "resolve with require_https names the source but not URL credentials when refusing http" do
      {
        "http://deploy-user:s3cr3t-token@app.miru.so" => "s3cr3t-token",
        "http://user:secret@app.miru.so" => "secret"
      }.each do |with_credentials, password|
        expect { described_class.resolve(app_base_url: with_credentials, fallback: "https://fallback.test", require_https: true) }
          .to raise_error(OmniauthFullHost::InvalidBaseUrl) { |error|
            expect(error.message).to include("APP_BASE_URL")
            expect(error.message).not_to include(password)
          }
      end
    end
  end
end

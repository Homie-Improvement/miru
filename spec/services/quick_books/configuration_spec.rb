# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickBooks::Configuration do
  around do |example|
    original_env = {
      "APP_BASE_URL" => ENV["APP_BASE_URL"],
      "INTUIT_REDIRECT_URI" => ENV["INTUIT_REDIRECT_URI"],
      "QUICKBOOKS_REDIRECT_URI" => ENV["QUICKBOOKS_REDIRECT_URI"],
      "QUICKBOOKS_WEBHOOK_VERIFIER_TOKEN" => ENV["QUICKBOOKS_WEBHOOK_VERIFIER_TOKEN"]
    }
    example.run
  ensure
    original_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  describe ".webhook_verifier_token" do
    it "reads the verifier token from the environment" do
      ENV["QUICKBOOKS_WEBHOOK_VERIFIER_TOKEN"] = "verifier-token"

      expect(described_class.webhook_verifier_token).to eq("verifier-token")
    end
  end

  describe ".redirect_uri" do
    around do |example|
      original_default_base_url = Rails.configuration.x.default_base_url
      Rails.configuration.x.default_base_url = "https://boot-check.test"
      example.run
    ensure
      Rails.configuration.x.default_base_url = original_default_base_url
    end

    before do
      ENV.delete("APP_BASE_URL")
      ENV.delete("INTUIT_REDIRECT_URI")
      ENV.delete("QUICKBOOKS_REDIRECT_URI")
    end

    it "uses config.x.default_base_url when APP_BASE_URL is unset" do
      expect(described_class.redirect_uri).to eq(
        "https://boot-check.test/api/v1/integrations/quickbooks/callback"
      )
    end

    it "uses config.x.default_base_url outside local Rails environments too" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)

      expect(described_class.redirect_uri).to eq(
        "https://boot-check.test/api/v1/integrations/quickbooks/callback"
      )
    end

    it "prefers a set APP_BASE_URL over config.x.default_base_url" do
      ENV["APP_BASE_URL"] = "https://app.miru.so"

      expect(described_class.redirect_uri).to eq(
        "https://app.miru.so/api/v1/integrations/quickbooks/callback"
      )
    end

    it "prefers QUICKBOOKS_REDIRECT_URI over both base URL sources" do
      ENV["APP_BASE_URL"] = "https://app.miru.so"
      ENV["QUICKBOOKS_REDIRECT_URI"] = "https://quickbooks.example/callback"

      expect(described_class.redirect_uri).to eq("https://quickbooks.example/callback")
    end
  end

  describe ".configured?" do
    before do
      ENV.delete("APP_BASE_URL")
      ENV.delete("INTUIT_REDIRECT_URI")
      ENV.delete("QUICKBOOKS_REDIRECT_URI")
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(described_class).to receive(:client_id).and_return("client-id")
      allow(described_class).to receive(:client_secret).and_return("client-secret")
    end

    # With APP_BASE_URL unset, the redirect uri now comes from config.x.default_base_url, so client
    # credentials alone make the integration configured. That uri must match the one registered with Intuit.
    it "needs no explicit redirect uri outside local Rails environments" do
      expect(described_class.configured?).to be(true)
    end
  end

  describe ".request_timeout_options" do
    it "sets bounded open and read timeouts for QuickBooks requests" do
      expect(described_class.request_timeout_options).to eq(
        open_timeout: 5,
        timeout: 15
      )
    end
  end
end

RSpec.describe QuickBooks::Configuration do
  # The QuickBooks OAuth redirect must come from the one validated base URL, so a
  # malformed APP_BASE_URL raises rather than sending users to a relative callback.
  it "redirect_uri refuses a schemeless APP_BASE_URL instead of building a relative OAuth callback" do
    original_env = %w[APP_BASE_URL INTUIT_REDIRECT_URI QUICKBOOKS_REDIRECT_URI].index_with { |key| ENV[key] }
    ENV.delete("INTUIT_REDIRECT_URI")
    ENV.delete("QUICKBOOKS_REDIRECT_URI")
    ENV["APP_BASE_URL"] = "evil.example"

    expect { described_class.redirect_uri }.to raise_error(AppBaseUrl::InvalidBaseUrl)
  ensure
    original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

RSpec.describe QuickBooks::Configuration do
  # "app/services/quick_books/configuration.rb, app/mcp/api_proxy.rb and the mailers no longer carry their own
  # APP_BASE_URL fallback literals; each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "builds the redirect uri from the swapped config.x.default_base_url in and outside local Rails environments when APP_BASE_URL is unset" do
    saved_env = %w[APP_BASE_URL INTUIT_REDIRECT_URI QUICKBOOKS_REDIRECT_URI].index_with { |key| ENV[key] }
    original_default_base_url = Rails.configuration.x.default_base_url
    saved_env.each_key { |key| ENV.delete(key) }
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    expect(described_class.redirect_uri).to eq("https://boot-check.test/api/v1/integrations/quickbooks/callback")

    allow(Rails.env).to receive(:development?).and_return(false)
    allow(Rails.env).to receive(:test?).and_return(false)
    expect(described_class.redirect_uri).to eq("https://boot-check.test/api/v1/integrations/quickbooks/callback")
  ensure
    saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe QuickBooks::Configuration do
  # Disclosed behaviour change: with APP_BASE_URL unset, production now builds a redirect uri from
  # config.x.default_base_url, so the integration counts as configured; that uri must match the one registered with Intuit.
  it "is configured outside local Rails environments from client credentials and the per-environment base URL alone" do
    saved_env = %w[APP_BASE_URL INTUIT_REDIRECT_URI QUICKBOOKS_REDIRECT_URI].index_with { |key| ENV[key] }
    original_default_base_url = Rails.configuration.x.default_base_url
    saved_env.each_key { |key| ENV.delete(key) }
    Rails.configuration.x.default_base_url = "https://boot-check.test"
    allow(Rails.env).to receive(:development?).and_return(false)
    allow(Rails.env).to receive(:test?).and_return(false)
    allow(described_class).to receive(:client_id).and_return("client-id")
    allow(described_class).to receive(:client_secret).and_return("client-secret")

    expect(described_class.configured?).to be(true)
  ensure
    saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe QuickBooks::Configuration do
  it "treats a whitespace APP_BASE_URL as unset when building the redirect uri" do
    saved_env = %w[APP_BASE_URL INTUIT_REDIRECT_URI QUICKBOOKS_REDIRECT_URI].index_with { |key| ENV[key] }
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("INTUIT_REDIRECT_URI")
    ENV.delete("QUICKBOOKS_REDIRECT_URI")
    ENV["APP_BASE_URL"] = "   "
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    expect(described_class.redirect_uri).to eq("https://boot-check.test/api/v1/integrations/quickbooks/callback")
  ensure
    saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

RSpec.describe QuickBooks::Configuration do
  # "each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "builds the redirect uri from a set APP_BASE_URL ahead of config.x.default_base_url and strips every trailing slash" do
    saved_env = %w[APP_BASE_URL INTUIT_REDIRECT_URI QUICKBOOKS_REDIRECT_URI].index_with { |key| ENV[key] }
    original_default = Rails.configuration.x.default_base_url
    ENV.delete("INTUIT_REDIRECT_URI")
    ENV.delete("QUICKBOOKS_REDIRECT_URI")
    ENV["APP_BASE_URL"] = "https://app.miru.so//"
    Rails.configuration.x.default_base_url = "https://boot-check.test"

    expect(described_class.redirect_uri).to eq("https://app.miru.so/api/v1/integrations/quickbooks/callback")
  ensure
    Rails.configuration.x.default_base_url = original_default
    saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

RSpec.describe QuickBooks::Configuration do
  # Acceptance: "app/services/quick_books/configuration.rb ... no longer carry their own APP_BASE_URL
  # fallback literals; each reads the one per-environment base URL (APP_BASE_URL, else
  # config.x.default_base_url)." Disclosed behaviour change: outside development and test this
  # now yields a redirect URI where it used to yield nil.
  it "builds the callback from config.x.default_base_url outside local environments when APP_BASE_URL is whitespace" do
    saved_env = %w[APP_BASE_URL INTUIT_REDIRECT_URI QUICKBOOKS_REDIRECT_URI].index_with { |key| ENV[key] }
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV["APP_BASE_URL"] = "  "
    ENV.delete("INTUIT_REDIRECT_URI")
    ENV.delete("QUICKBOOKS_REDIRECT_URI")
    Rails.configuration.x.default_base_url = "https://boot-check.test/"
    allow(Rails.env).to receive(:development?).and_return(false)
    allow(Rails.env).to receive(:test?).and_return(false)

    expect(described_class.redirect_uri).to eq("https://boot-check.test/api/v1/integrations/quickbooks/callback")
  ensure
    saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

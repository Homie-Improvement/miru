# frozen_string_literal: true

require "rails_helper"

RSpec.describe "with_app_base_url spec helper" do
  # This spec cannot use the helper to protect itself, so it saves and restores
  # both base URL sources directly.
  around do |example|
    saved_env = ENV.fetch("APP_BASE_URL", nil)
    saved_default = Rails.configuration.x.default_base_url
    example.run
  ensure
    ENV["APP_BASE_URL"] = saved_env
    Rails.configuration.x.default_base_url = saved_default
  end

  # The examples that use the helper no longer have their own ensure blocks, so
  # a restore skipped on raise would leak into every later example.
  it "restores both values and re-raises when the block raises" do
    ENV["APP_BASE_URL"] = "https://prior.test"
    Rails.configuration.x.default_base_url = "http://example.com"

    expect do
      with_app_base_url(env: nil, default: "https://boot-check.test") { raise ArgumentError, "boom" }
    end.to raise_error(ArgumentError, "boom")

    expect(ENV.fetch("APP_BASE_URL", nil)).to eq("https://prior.test")
    expect(Rails.configuration.x.default_base_url).to eq("http://example.com")
  end

  it "leaves APP_BASE_URL absent afterwards when it was unset before" do
    ENV.delete("APP_BASE_URL")

    with_app_base_url(env: "https://inside.test", default: "https://boot-check.test") { nil }

    expect(ENV.key?("APP_BASE_URL")).to be(false)
  end

  # If APP_BASE_URL stayed set, AppBaseUrl.current would return it and the
  # swapped default would never be read.
  it "removes APP_BASE_URL and sets the default inside the block when env is nil" do
    ENV["APP_BASE_URL"] = "https://prior.test"
    seen = nil

    with_app_base_url(env: nil, default: "https://boot-check.test") do
      seen = { env_present: ENV.key?("APP_BASE_URL"), default: Rails.configuration.x.default_base_url }
    end

    expect(seen).to eq(env_present: false, default: "https://boot-check.test")
  end

  it "sets APP_BASE_URL to the exact env value passed in, whitespace included" do
    seen = nil

    with_app_base_url(env: "   ", default: "https://boot-check.test") { seen = ENV.fetch("APP_BASE_URL", nil) }

    expect(seen).to eq("   ")
  end

  it "returns the block's value" do
    result = with_app_base_url(env: nil, default: "https://boot-check.test") { :block_result }

    expect(result).to eq(:block_result)
  end

  # Some specs change both values several times inside one example; the helper
  # must still put back what was there before it ran.
  it "restores the earlier values even when the block reassigns both" do
    ENV["APP_BASE_URL"] = "https://prior.test"
    Rails.configuration.x.default_base_url = "http://example.com"

    with_app_base_url(env: nil, default: "https://boot-check.test") do
      ENV["APP_BASE_URL"] = "https://app.miru.so:8443"
      Rails.configuration.x.default_base_url = "http://boot-check.test:4000"
    end

    expect(ENV.fetch("APP_BASE_URL", nil)).to eq("https://prior.test")
    expect(Rails.configuration.x.default_base_url).to eq("http://example.com")
  end
end

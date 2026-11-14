# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OmniAuth full host pin against forged forwarding headers", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ENV.delete("APP_BASE_URL")
    ActionController::Base.allow_forgery_protection = false
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset,
  # and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  # OmniAuth's own fallback also reads X-Forwarded-Host and X-Forwarded-Proto, so forging those must not move it either.
  it "keeps the GitHub callback on the configured host when Host and X-Forwarded-* headers are forged and APP_BASE_URL is unset" do
    post "/users/auth/github",
      headers: {
        "Host" => "evil.example",
        "X-Forwarded-Host" => "evil.example",
        "X-Forwarded-Proto" => "https",
        "X-Forwarded-Port" => "8443"
      }

    expect(response).to have_http_status(:redirect)
    callback = URI.parse(response.location)
    expect(callback.scheme).to eq("http")
    expect(callback.host).to eq("example.com")
    expect(callback.port).to eq(80)
    expect(callback.path).to eq("/users/auth/github/callback")
  end
end

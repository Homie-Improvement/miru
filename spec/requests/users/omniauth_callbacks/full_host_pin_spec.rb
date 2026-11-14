# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OmniAuth full host pin: spoofed Host on GitHub", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    ENV.delete("APP_BASE_URL")
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset, and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  it "builds the GitHub callback on the configured host when the Host header is spoofed and APP_BASE_URL is unset" do
    post "/users/auth/github", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    callback = URI.parse(response.location)
    expect(callback.host).to eq("example.com")
    expect(callback.host).not_to eq("evil.example")
    expect("#{callback.scheme}://#{callback.host}#{callback.path}").to eq("http://example.com/users/auth/github/callback")
  end
end

RSpec.describe "OmniAuth full host pin: forged forwarding headers", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    ENV.delete("APP_BASE_URL")
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

  # The forwarding headers are as untrusted as Host: OmniAuth's own fallback reads them,
  # so a pin that only covered Host would still let an attacker steer the callback.
  it "ignores forged X-Forwarded-Host and X-Forwarded-Proto when building the GitHub callback" do
    post "/users/auth/github",
      headers: { "X-Forwarded-Host" => "evil.example", "X-Forwarded-Proto" => "https" }

    expect(response).to have_http_status(:redirect)
    callback = URI.parse(response.location)
    expect("#{callback.scheme}://#{callback.host}#{callback.path}").to eq("http://example.com/users/auth/github/callback")
  end
end

RSpec.describe "OmniAuth full host pin: spoofed Host on Google", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    ENV.delete("APP_BASE_URL")
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:google_oauth2] = build(:google_user_data) }

  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset, and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  it "builds the Google callback on the configured host when the Host header is spoofed and APP_BASE_URL is unset" do
    post "/users/auth/google_oauth2", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    callback = URI.parse(response.location)
    expect("#{callback.scheme}://#{callback.host}#{callback.path}").to eq("http://example.com/users/auth/google_oauth2/callback")
  end
end

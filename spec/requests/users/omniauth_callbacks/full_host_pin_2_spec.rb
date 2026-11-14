# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OmniAuth full host pin at boot", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    ENV.delete("APP_BASE_URL")
    OmniAuth.config.full_host = nil
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset, and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  it "boot pins full_host to the environment's declared base URL when APP_BASE_URL is unset" do
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s

    expect(OmniAuth.config.full_host).to eq("http://example.com")
    expect(OmniAuth.config.full_host).to eq(Rails.configuration.x.default_base_url)
  end
end

RSpec.describe "OmniAuth full host pin against a spoofed Host header", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ENV.delete("APP_BASE_URL")
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

  # "OmniAuth's full_host is set from a required per-environment config value when APP_BASE_URL is unset, and a spec shows that a request with a spoofed Host header still builds its callback URL on the configured host."
  it "a spoofed Host header follows the request when unpinned but stays on the configured host once booted" do
    # Control: without a pin the callback follows the forged header, so the
    # pinned assertion below cannot pass just because the host is never read.
    OmniAuth.config.full_host = nil
    post "/users/auth/github", headers: { "Host" => "evil.example" }
    expect(response).to have_http_status(:redirect)
    expect(URI.parse(response.location).host).to eq("evil.example")

    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
    post "/users/auth/github", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to start_with("http://example.com/users/auth/github/callback")
    expect(URI.parse(response.location).host).to eq("example.com")
  end
end

RSpec.describe "OmniAuth full host pin against forwarded headers", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ENV.delete("APP_BASE_URL")
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

  it "forged X-Forwarded-Host and X-Forwarded-Proto do not move the pinned GitHub callback" do
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s

    post "/users/auth/github",
      headers: { "X-Forwarded-Host" => "evil.example", "X-Forwarded-Proto" => "https" }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to start_with("http://example.com/users/auth/github/callback")
  end
end

RSpec.describe "OmniAuth full host pin for Google sign-in", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ENV.delete("APP_BASE_URL")
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:google_oauth2] = build(:google_user_data) }

  it "a spoofed Host header does not move the pinned Google callback" do
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s

    post "/users/auth/google_oauth2", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to start_with("http://example.com/users/auth/google_oauth2/callback")
  end
end

RSpec.describe "OmniAuth full host pin with APP_BASE_URL set", type: :request do
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ENV["APP_BASE_URL"] = "https://app.miru.so"
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

  it "a set APP_BASE_URL still wins over the environment default and a spoofed Host" do
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s

    post "/users/auth/github", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to start_with("https://app.miru.so/users/auth/github/callback")
  end
end

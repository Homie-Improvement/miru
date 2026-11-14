# frozen_string_literal: true

require "rails_helper"

# Drives the OmniAuth request phase with forged headers against the host that
# config/initializers/omniauth_full_host.rb pins at boot.
RSpec.describe "OmniAuth full host pin", type: :request do
  let(:app_base_url) { nil }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  before do
    ENV["APP_BASE_URL"] = app_base_url
    OmniAuth.config.mock_auth[:github] = build(:github_user_data)
    OmniAuth.config.mock_auth[:google_oauth2] = build(:google_user_data)
  end

  def pin_full_host_at_boot
    load Rails.root.join("config/initializers/omniauth_full_host.rb").to_s
  end

  def callback_url_without_query
    callback = URI.parse(response.location)
    "#{callback.scheme}://#{callback.host}#{callback.path}"
  end

  it "a spoofed Host header follows the request when unpinned but stays on the configured host once booted" do
    # Control: without a pin the callback follows the forged header, so the
    # pinned assertion below cannot pass just because the host is never read.
    OmniAuth.config.full_host = nil
    post "/users/auth/github", headers: { "Host" => "evil.example" }
    expect(response).to have_http_status(:redirect)
    expect(URI.parse(response.location).host).to eq("evil.example")

    pin_full_host_at_boot
    post "/users/auth/github", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    expect(callback_url_without_query).to eq("http://example.com/users/auth/github/callback")
  end

  # OmniAuth's own fallback also reads the forwarding headers, so a pin that only
  # covered Host would still let an attacker steer the callback.
  it "ignores forged X-Forwarded-Host and X-Forwarded-Proto when building the GitHub callback" do
    pin_full_host_at_boot

    post "/users/auth/github",
      headers: { "X-Forwarded-Host" => "evil.example", "X-Forwarded-Proto" => "https" }

    expect(response).to have_http_status(:redirect)
    expect(callback_url_without_query).to eq("http://example.com/users/auth/github/callback")
  end

  it "keeps the GitHub callback on the configured host when Host and X-Forwarded-* headers are forged and APP_BASE_URL is unset" do
    pin_full_host_at_boot

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

  it "builds the Google callback on the configured host when the Host header is spoofed and APP_BASE_URL is unset" do
    pin_full_host_at_boot

    post "/users/auth/google_oauth2", headers: { "Host" => "evil.example" }

    expect(response).to have_http_status(:redirect)
    expect(callback_url_without_query).to eq("http://example.com/users/auth/google_oauth2/callback")
  end

  context "with APP_BASE_URL set" do
    let(:app_base_url) { "https://app.miru.so" }

    it "a set APP_BASE_URL still wins over the environment default and a spoofed Host" do
      pin_full_host_at_boot

      post "/users/auth/github", headers: { "Host" => "evil.example" }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to start_with("https://app.miru.so/users/auth/github/callback")
    end
  end
end

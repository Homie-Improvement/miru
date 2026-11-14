# frozen_string_literal: true

require "rails_helper"

# Drives the OmniAuth request phase through the real middleware, so an OmniAuth upgrade
# that stops calling the app's CSRF verifier (config/initializers/omniauth_rails_csrf_protection.rb)
# fails here.
RSpec.describe "OmniAuth request phase CSRF protection", type: :request do
  around do |example|
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = forgery_protection
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  let(:forgery_protection) { true }

  # The verifier either raises ActionController::InvalidAuthenticityToken or OmniAuth turns
  # the error into a failure response; either way the request must not go on to the
  # provider or the callback.
  def refused_sign_in_request?(path, callback_path:, provider_host:, params: {})
    post(path, params:)
    location = response.location.to_s
    !(location.include?(callback_path) || location.include?(provider_host))
  rescue ActionController::InvalidAuthenticityToken
    true
  end

  def authenticity_token_from_page
    get root_path
    follow_redirect! while response.redirect?
    response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
  end

  describe "GitHub" do
    before { OmniAuth.config.mock_auth[:github] = build(:github_user_data) }

    it "refuses a sign-in request that carries no authenticity token" do
      expect(
        refused_sign_in_request?(
          "/users/auth/github", callback_path: "/users/auth/github/callback", provider_host: "github.com")
      ).to be(true)
    end

    it "refuses a sign-in request that carries a forged authenticity token" do
      expect(
        refused_sign_in_request?(
          "/users/auth/github",
          callback_path: "/users/auth/github/callback",
          provider_host: "github.com",
          params: { authenticity_token: "forged-token-not-from-this-session" })
      ).to be(true)
    end

    it "lets a sign-in request with a valid authenticity token reach the callback" do
      token = authenticity_token_from_page
      expect(token).to be_present

      post "/users/auth/github", params: { authenticity_token: token }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("/users/auth/github/callback")
    end

    context "when forgery protection is off" do
      let(:forgery_protection) { false }

      # Shows the refusals above come from the CSRF check, not from a broken request phase.
      it "hands a sign-in request to the mock callback" do
        post "/users/auth/github"

        expect(response).to have_http_status(:redirect)
        expect(response.location).to include("/users/auth/github/callback")
      end
    end
  end

  describe "Google" do
    before { OmniAuth.config.mock_auth[:google_oauth2] = build(:google_user_data) }

    it "refuses a sign-in request that carries no authenticity token" do
      expect(
        refused_sign_in_request?(
          "/users/auth/google_oauth2",
          callback_path: "/users/auth/google_oauth2/callback",
          provider_host: "accounts.google.com")
      ).to be(true)
    end

    it "lets a sign-in request with a valid authenticity token reach the callback" do
      token = authenticity_token_from_page
      expect(token).to be_present

      post "/users/auth/google_oauth2", params: { authenticity_token: token }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("/users/auth/google_oauth2/callback")
    end
  end
end

RSpec.describe "OmniAuth advisory floor" do
  # The advisory reads: "Name: omniauth Version: 2.1.4 CVE: CVE-2026-63183 Title: OmniAuth - Host Header Injection Vulnerability Solution: update to '>= 2.2.0'"
  it "CVE-2026-63183: omniauth is at least 2.2.0" do
    expect(Gem.loaded_specs["omniauth"].version).to be >= Gem::Version.new("2.2.0")
  end
end

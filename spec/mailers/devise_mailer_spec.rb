# frozen_string_literal: true

require "rails_helper"

RSpec.describe Devise::Mailer, type: :mailer do
  describe "email_changed" do
    it "includes the support alias in the body" do
      user = create(:user)

      mail = described_class.email_changed(user)

      expect(mail.body.encoded).to include("hello@saeloun.com")
    end
  end

  describe "password_change" do
    it "includes the support alias in the body" do
      user = create(:user)

      mail = described_class.password_change(user)

      expect(mail.body.encoded).to include("hello@saeloun.com")
    end
  end

  describe "unlock_instructions" do
    it "explains the timed lock behavior and points to sign in" do
      user = create(:user)

      mail = described_class.unlock_instructions(user, "preview-unlock-token")

      expect(mail.body.encoded).to include("30 minutes")
      expect(mail.body.encoded).to include("/password/new")
      expect(mail.body.encoded).to include("secure once the lock expires")
    end
  end
end

require "rails_helper"

RSpec.describe Devise::Mailer, type: :mailer do
  # "app/services/quick_books/configuration.rb, app/mcp/api_proxy.rb and the mailers no longer carry their own
  # APP_BASE_URL fallback literals; each reads the one per-environment base URL (APP_BASE_URL, else config.x.default_base_url)."
  it "points the unlock email at the swapped config.x.default_base_url instead of 127.0.0.1 when APP_BASE_URL is unset" do
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "https://boot-check.test"
    user = create(:user)

    body = described_class.unlock_instructions(user, "preview-unlock-token").body.decoded

    expect(body).to include("https://boot-check.test/password/new")
    expect(body).not_to include("127.0.0.1")
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end
end

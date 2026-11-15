# frozen_string_literal: true

# == Schema Information
#
# Table name: stripe_connected_accounts
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :string           not null
#  company_id :bigint           not null
#
# Indexes
#
#  index_stripe_connected_accounts_on_account_id  (account_id) UNIQUE
#  index_stripe_connected_accounts_on_company_id  (company_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (company_id => companies.id)
#
require "rails_helper"

RSpec.describe StripeConnectedAccount, type: :model do
  subject(:stripe_connected_account) { build(:stripe_connected_account) }

  describe "Validations" do
    describe "validate uniqueness of" do
      it do
        allow(Stripe::Account).to receive(:create)
          .and_return(OpenStruct.new({ id: stripe_connected_account.account_id }))
        expect(subject).to validate_uniqueness_of(:account_id)
      end
    end
  end

  describe "Associations" do
    describe "belongs to" do
      it { is_expected.to belong_to(:company) }
    end
  end

  describe "Instance methods" do
    describe "#details_submitted" do
      it "returns false" do
        allow(Stripe::Account).to receive(:retrieve)
          .and_return(OpenStruct.new({ details_submitted: false }))
        expect(stripe_connected_account.details_submitted).to be(false)
      end

      it "returns true" do
        allow(Stripe::Account).to receive(:retrieve)
          .and_return(OpenStruct.new({ details_submitted: true }))
        expect(stripe_connected_account.details_submitted).to be(true)
      end

      it "returns false when Stripe cannot retrieve the account" do
        allow(Stripe::Account).to receive(:retrieve)
          .and_raise(Stripe::AuthenticationError.new("No API key provided"))

        expect(stripe_connected_account.details_submitted).to be(false)
      end
    end

    describe "#url" do
      it "returns non nil url" do
        allow(Stripe::AccountLink).to receive(:create)
          .and_return(OpenStruct.new({ url: "https://connect.stripe.com/setup/s/something" }))
        allow(Stripe::Account).to receive(:retrieve)
          .and_return(OpenStruct.new({ details_submitted: false }))
        expect(stripe_connected_account.url).to be("https://connect.stripe.com/setup/s/something")
      end

      it "returns nil" do
        allow(Stripe::AccountLink).to receive(:create)
          .and_return(OpenStruct.new({ url: "https://connect.stripe.com/setup/s/something" }))
        allow(Stripe::Account).to receive(:retrieve)
          .and_return(OpenStruct.new({ details_submitted: true }))
        expect(stripe_connected_account.url).to be(nil)
      end
    end
  end
end

RSpec.describe StripeConnectedAccount, type: :model do
  subject(:stripe_connected_account) { build(:stripe_connected_account) }

  # AppBaseUrl.current re-reads ENV and the setting on every call, so both are restored after each
  # example. The swapped default differs from test.rb's "http://example.com", so a hard-coded
  # literal cannot pass.
  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_default_base_url = Rails.configuration.x.default_base_url
    Rails.configuration.x.default_base_url = "https://boot-check.test"
    example.run
  ensure
    original_app_base_url.nil? ? ENV.delete("APP_BASE_URL") : ENV["APP_BASE_URL"] = original_app_base_url
    Rails.configuration.x.default_base_url = original_default_base_url
  end

  before do
    allow(Stripe::Account).to receive(:retrieve)
      .and_return(OpenStruct.new({ details_submitted: false }))
    allow(Stripe::AccountLink).to receive(:create)
      .and_return(OpenStruct.new({ url: "https://connect.stripe.com/x" }))
  end

  it "builds Stripe Connect refresh and return URLs from the config.x.default_base_url fallback when APP_BASE_URL is unset" do
    ENV.delete("APP_BASE_URL")

    expect(stripe_connected_account.url).to eq("https://connect.stripe.com/x")
    expect(Stripe::AccountLink).to have_received(:create).with(
      hash_including(
        refresh_url: "https://boot-check.test/payments/settings/stripe/connect/refresh",
        return_url: "https://boot-check.test/settings/payment"
      )
    )
  end

  # A whitespace-only APP_BASE_URL is non-empty, so a raw ENV read builds a link with a blank host.
  it "treats a whitespace-only APP_BASE_URL as unset and builds both Stripe Connect links from config.x.default_base_url" do
    ENV["APP_BASE_URL"] = "   "

    expect(stripe_connected_account.url).to eq("https://connect.stripe.com/x")
    expect(Stripe::AccountLink).to have_received(:create).with(
      hash_including(
        refresh_url: "https://boot-check.test/payments/settings/stripe/connect/refresh",
        return_url: "https://boot-check.test/settings/payment"
      )
    )
  end

  # Exact strings catch a doubled slash, a lost scheme or a doubled scheme.
  it "builds Stripe Connect URLs without a doubled slash when APP_BASE_URL ends in a slash" do
    ENV["APP_BASE_URL"] = "https://app.example.test/"

    stripe_connected_account.url

    expect(Stripe::AccountLink).to have_received(:create).with(
      hash_including(
        refresh_url: "https://app.example.test/payments/settings/stripe/connect/refresh",
        return_url: "https://app.example.test/settings/payment"
      )
    )
  end

  it "raises AppBaseUrl::InvalidBaseUrl instead of sending Stripe a broken link when APP_BASE_URL is malformed" do
    ENV["APP_BASE_URL"] = "not a url"

    expect { stripe_connected_account.url }.to raise_error(AppBaseUrl::InvalidBaseUrl)
    expect(Stripe::AccountLink).not_to have_received(:create)
  end

  it "refuses a non-http APP_BASE_URL with AppBaseUrl::InvalidBaseUrl and sends no onboarding link to Stripe" do
    ENV["APP_BASE_URL"] = "ftp://files.example.test"

    expect { stripe_connected_account.url }.to raise_error(AppBaseUrl::InvalidBaseUrl)
    expect(Stripe::AccountLink).not_to have_received(:create)
  end
end

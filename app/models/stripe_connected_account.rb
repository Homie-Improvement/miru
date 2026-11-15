# frozen_string_literal: true

class StripeConnectedAccount < ApplicationRecord
  include Rails.application.routes.url_helpers

  before_create do
    self.account_id ||= Stripe::Account.create(type: "standard").id
  end

  belongs_to :company

  validates :account_id, uniqueness: true

  def details_submitted
    retrieve.details_submitted
  rescue Stripe::StripeError => e
    Rails.logger.warn(
      "Unable to retrieve Stripe connected account #{account_id}: #{e.class} - #{e.message}"
    )
    false
  end

  def url
    return if details_submitted

    base_url = AppBaseUrl.current
    Stripe::AccountLink.create(
      type: "account_onboarding",
      account: self.account_id,
      refresh_url: "#{base_url}#{payments_settings_stripe_connect_refresh_path}",
      return_url: "#{base_url}/settings/payment"
    ).url
  end

  private

    def retrieve
      Stripe::Account.retrieve(self.account_id)
    end
end

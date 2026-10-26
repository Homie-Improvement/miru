# frozen_string_literal: true

# The one answer to a billing or entry write refused during a Timekeeping
# handoff: 503 with reason ownership_moving and a Retry-After hint. The body
# carries a fixed message and the reason only, never the handoff state,
# because every company's callers see this same global refusal.
#
# Kept apart from ErrorHandler so controllers that do not include it, such as
# webhook controllers built on ActionController::API, render the same answer.
module OwnershipMovingResponse
  extend ActiveSupport::Concern

  REASON = "ownership_moving"

  # The message key for each refusal class. Entry writes get their own text,
  # because the billing text tells the user billing is paused.
  MESSAGE_KEYS = {
    "Timekeeping::Gateway::OwnershipMoving" => "errors.entry_ownership_moving"
  }.freeze
  DEFAULT_MESSAGE_KEY = "errors.ownership_moving"

  private

    # A browser opening a page, such as the payer's pay and return pages, gets
    # an error page. Every other caller gets JSON, including provider webhooks,
    # which POST without an Accept header and so default to the HTML format.
    def render_ownership_moving(exception = nil)
      response.headers["Retry-After"] = Timekeeping::BillingFence::RETRY_AFTER_SECONDS.to_s
      if request.get? && request.format.html?
        render file: Rails.public_path.join("500.html"), status: 503, layout: false
      else
        message = I18n.t(MESSAGE_KEYS.fetch(exception.class.name, DEFAULT_MESSAGE_KEY))
        render json: { errors: message, reason: REASON }, status: 503
      end
    end
end

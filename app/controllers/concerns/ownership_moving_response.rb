# frozen_string_literal: true

# The one answer to a billing write refused during a Timekeeping handoff:
# 503 with reason ownership_moving and a Retry-After hint. The body carries a
# fixed message and the reason only, never the handoff state, because every
# company's callers see this same global refusal.
#
# Kept apart from ErrorHandler so controllers that do not include it, such as
# webhook controllers built on ActionController::API, render the same answer.
module OwnershipMovingResponse
  extend ActiveSupport::Concern

  REASON = "ownership_moving"

  private

    def render_ownership_moving(_exception = nil)
      response.headers["Retry-After"] = Timekeeping::BillingFence::RETRY_AFTER_SECONDS.to_s
      render json: { errors: I18n.t("errors.ownership_moving"), reason: REASON }, status: 503
    end
end

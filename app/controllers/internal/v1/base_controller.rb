# frozen_string_literal: true

# Base for endpoints the Timekeeping service calls. It inherits from
# ActionController::API directly, so no user session, x-auth-token or Pundit
# filter exists here to let a user in: the only accepted credential is the
# Timekeeping service token.
class Internal::V1::BaseController < ActionController::API
  SERVICE_TOKEN_ENV = "TIMEKEEPING_SERVICE_TOKEN"

  before_action :authenticate_timekeeping_service!

  private

    # Refuses every request when the token is not configured, so a host with a
    # missing secret never accepts an empty credential.
    def authenticate_timekeeping_service!
      expected = ENV[SERVICE_TOKEN_ENV].to_s
      presented = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
      return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(presented, expected)

      render_reason(:unauthorized)
    end

    def render_reason(reason, status: reason)
      render json: { reason: }, status:
    end
end

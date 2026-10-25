# frozen_string_literal: true

# Every route reads the caller from the identity Timekeeping::RequestIdentity
# stored for this request; no header or body field names the user, company or
# role. Error bodies hold only the contract's reason.
class ApplicationController < ActionController::API
  before_action :authorize_read!

  private

    def identity
      Timekeeping::RequestIdentity.from(request.env)
    end

    def authorize_read!
      decision = Timekeeping::ReadAccess.decide(identity, path_company_id: params[:company_id])
      render_reason(decision) unless decision == :allowed
    end

    # What Timekeeping::EntriesQuery needs, from the verified claims only.
    def visibility
      { company_id: identity.company_id, role: identity.role, acting_user_id: identity.user_id }
    end

    def render_reason(reason)
      render json: { reason: }, status: Timekeeping::Reasons.status(reason)
    end
end

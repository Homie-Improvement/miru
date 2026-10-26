# frozen_string_literal: true

module Timekeeping
  # Decides whether a request may use an internal, service-only route. Only the
  # unbound service identity passes: Timekeeping::Identity resolves it only for
  # a bearer equal to a non-empty TIMEKEEPING_SERVICE_TOKEN, so an empty
  # variable lets nobody in. User tokens of every role are refused, because
  # these routes answer for every company at once, and so is a signed service
  # token, because it is bound to one company.
  module ServiceAccess
    module_function

    def decide(identity)
      identity.kind == :service && identity.company_id.nil? ? :allowed : :unauthorized
    end
  end
end

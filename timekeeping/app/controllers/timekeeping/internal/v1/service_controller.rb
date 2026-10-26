# frozen_string_literal: true

# The base of every internal route. These routes answer for every company at
# once, so only the service identity may call them; a user token of any role
# is refused before any action runs.
class Timekeeping::Internal::V1::ServiceController < ApplicationController
  skip_before_action :authorize_read!
  before_action :authorize_service!

  private

    def authorize_service!
      decision = Timekeeping::ServiceAccess.decide(identity)
      render_reason(decision) unless decision == :allowed
    end
end

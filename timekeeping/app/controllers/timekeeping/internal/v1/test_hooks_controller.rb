# frozen_string_literal: true

# Pauses and resumes snapshot delivery for the integration tests. The routes
# exist only when Timekeeping::TestHooks is loaded. A pause stops every
# company's entries reaching the monolith, so only the service identity may
# call them.
class Timekeeping::Internal::V1::TestHooksController < ApplicationController
  skip_before_action :authorize_read!
  before_action :authorize_service!

  def pause
    Timekeeping::TestHooks.pause_relay!
    head :no_content
  end

  def resume
    Timekeeping::TestHooks.resume_relay!
    head :no_content
  end
end

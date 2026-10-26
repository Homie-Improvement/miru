# frozen_string_literal: true

# The reservation routes and service commands. Only a signed service token
# bound to the path's company and listing the route's operation reaches an
# action; Timekeeping::ReservationRequest checks the body and the commands do
# the work.
class Timekeeping::V1::ReservationsController < ApplicationController
  # The route each action serves. abort is a Kernel method, so its action
  # takes another name.
  ACTION_ROUTES = {
    "prepare" => :prepare,
    "commit" => :commit,
    "abort_operation" => :abort,
    "mark_billed" => :mark_billed,
    "detach_entries" => :detach_entries
  }.freeze

  # These routes admit service tokens only, so they take their own access
  # decision instead of the read routes'.
  skip_before_action :authorize_read!
  before_action :authorize_service!

  # A body that is not JSON, or holds a value of the wrong shape, gets the same
  # {reason: ...} body as every other refusal, never the framework's own page.
  rescue_from ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError do
    render_reason(:invalid_request)
  end

  def prepare = run
  def commit = run
  def abort_operation = run
  def mark_billed = run
  def detach_entries = run

  private

    def route
      ACTION_ROUTES.fetch(action_name)
    end

    def authorize_service!
      decision = Timekeeping::ReservationAccess.decide(
        identity:, company_id: params[:company_id], operation: Timekeeping::ReservationAccess::ROUTE_OPERATIONS.fetch(route)
      )
      render_reason(decision) unless decision == :allowed
    end

    def run
      # Read from the path only, so a body field of the same name never
      # stands in for the path's invoice or agent.
      path_id = request.path_parameters[:invoice_id] || request.path_parameters[:agent_id]
      request_value = Timekeeping::ReservationRequest.build(
        route:, identity:, path_id:, raw_body: request.raw_post,
        bearer: Timekeeping::Identity.bearer(request.authorization)
      )
      outcome = if request_value.is_a?(Timekeeping::WriteOutcome)
        request_value
      else
        Timekeeping::ReservationRequest.handler(route).new.call(request_value)
      end
      render json: outcome.body, status: outcome.status
    end
end

# frozen_string_literal: true

class Timekeeping::V1::EntriesController < ApplicationController
  LIST_FILTERS = %w[from to user_id project_id].freeze
  WRITE_ACTIONS = %i[create update destroy bulk_move bulk_delete].freeze

  include Timekeeping::WriteMetricsRecording

  # Writes answer an expired token with 503 instead of the read routes' 401,
  # so they take their own access decision.
  skip_before_action :authorize_read!, only: WRITE_ACTIONS
  # Declared before the access check so refusals are measured too.
  around_action :record_write_metric, only: WRITE_ACTIONS
  before_action :authorize_write!, only: WRITE_ACTIONS

  # A body that is not JSON, or holds a value of the wrong shape, gets the same
  # {reason: ...} body as every other refusal, never the framework's own page.
  rescue_from ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError do
    render_reason(:invalid_request)
  end

  def index
    entries = Timekeeping::EntriesQuery.visible(**visibility, filters: request.query_parameters.slice(*LIST_FILTERS))
    render json: { entries: entries.map { |entry| Timekeeping::EntryPresenter.call(entry) } }
  end

  def show
    entry = Timekeeping::EntriesQuery.find_visible(params[:entry_id], **visibility)
    return render_reason(:not_found) unless entry

    render json: Timekeeping::EntryPresenter.call(entry)
  end

  def create = write(:create)
  def update = write(:update)
  def destroy = write(:destroy)
  def bulk_move = write(:bulk_move)
  def bulk_delete = write(:bulk_delete)

  private

    def authorize_write!
      decision = Timekeeping::WriteAccess.decide(identity, path_company_id: params[:company_id])
      render_reason(decision) unless decision == :allowed
    end

    def write(route)
      command = Timekeeping::EntryCommand.build(
        route:, identity:, company_id: identity.company_id, entry_id: params[:entry_id], headers: request.headers,
        raw_body: request.raw_post, bearer: Timekeeping::Identity.bearer(request.authorization),
        reference_client: Timekeeping::ReferenceClient.configured
      )
      outcome = command.is_a?(Timekeeping::WriteOutcome) ? command : entry_writer.call(command)
      render json: outcome.body, status: outcome.status
    end

    # Only the test environment sets entry_write_checkpoint; everywhere else the
    # writer runs with its own no-op checkpoint.
    def entry_writer
      checkpoint = Rails.configuration.x.entry_write_checkpoint
      checkpoint ? Timekeeping::EntryWriter.new(checkpoint:) : Timekeeping::EntryWriter.new
    end
end

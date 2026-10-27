# frozen_string_literal: true

module ErrorHandler
  extend ActiveSupport::Concern
  include OwnershipMovingResponse

  included do
    rescue_from ActionController::RoutingError, ActiveRecord::RecordNotFound, with: :handle_not_found_error
    rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
    rescue_from Discard::RecordNotDiscarded, with: :record_not_discarded
    rescue_from ActiveRecord::RecordInvalid, with: :record_invalid
    rescue_from Pagy::VariableError, with: :invalid_param_value
    rescue_from Timekeeping::EntryApiClient::Error, with: :timekeeping_unavailable
    rescue_from Timekeeping::BillingFence::OwnershipMoving, with: :render_ownership_moving
    rescue_from Timekeeping::Gateway::StaleGeneration, with: :render_stale_generation
    rescue_from Timekeeping::EntryWriteClient::Forbidden, with: :render_timekeeping_forbidden
    rescue_from Timekeeping::EntryWriteClient::Conflict, with: :render_entry_version_conflict
    rescue_from Timekeeping::EntryWriteClient::Rejected, with: :render_entry_write_rejected
    rescue_from Invoices::OperationErrors::Refused, with: :reservation_refused
    rescue_from Invoices::OperationErrors::Retryable, with: :reservation_retryable
  end

  STALE_GENERATION_REASON = "stale_generation"
  VERSION_CONFLICT_REASON = "version_conflict"

  # What a caller is told for each reason an invoice save was refused. The
  # text never names the invoice that holds the entry.
  RESERVATION_REFUSAL_MESSAGES = {
    "on_another_invoice" => "entry is on another invoice",
    "provisional_elsewhere" => "entry is being added to another invoice",
    "not_found" => "entry not found"
  }.freeze
  DEFAULT_RESERVATION_REFUSAL_MESSAGE = "entry cannot be added to this invoice"
  RESERVATION_RETRYABLE_MESSAGE = "invoice could not be saved right now, please try again"

  private

    def reservation_refused(exception)
      reason = exception.outcome&.conflicts&.first&.fetch(:reason)
      message = RESERVATION_REFUSAL_MESSAGES.fetch(reason, DEFAULT_RESERVATION_REFUSAL_MESSAGE)

      respond_to do |format|
        format.json { render json: { errors: message }, status: 422 }
        format.html do
          flash.now[:alert] = message
          render file: "public/422.html", status: 422, layout: false
        end
      end
    end

    # The reservation store did not settle the save, for example when its
    # answer was lost. Nothing was saved and the save may be sent again. The
    # error's own message is an internal reason, so it is not shown.
    def reservation_retryable(_exception)
      respond_to do |format|
        format.json { render json: { errors: RESERVATION_RETRYABLE_MESSAGE }, status: 503 }
        format.html do
          flash.now[:alert] = RESERVATION_RETRYABLE_MESSAGE
          render file: "public/500.html", status: 503, layout: false
        end
      end
    end

    def handle_not_found_error(exception)
      message = exception.message || I18n.t("errors.not_found")

      respond_to do |format|
        format.json { render json: { errors: message }, status: 404 }
        format.html { render file: "public/404.html", status: 404, layout: false, alert: message }
      end
    end

    def user_not_authorized(exception)
      redirect_path = root_path
      policy = exception.policy
      policy_name = policy.class.to_s.underscore
      error_key = policy.try(:error_message_key) || exception.query

      message = I18n.t("#{policy_name}.#{error_key}", scope: "pundit", default: :default)
      message = I18n.t("pundit.different_workspace") if policy.try(:error_message_key) == :different_workspace

      respond_to do |format|
        format.html do
          flash.now[:alert] = message
          redirect_to redirect_path
        end
        format.json { render json: { errors: message }, status: 403 }
        format.any(:pdf, :csv) { render json: { errors: message }, status: 403 }
      end
    end

    def record_not_discarded(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: message }, status: 500 }
        format.html { render file: "public/500.html", status: 500, layout: false, alert: message }
      end
    end

    def record_invalid(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: exception.record.errors.full_messages.first }, status: 422 }
        format.html { render file: "public/422.html", status: 422, layout: false, alert: message }
      end
    end

    # The Timekeeping service owns entries and could not be read. The read
    # never falls back to the projection, so the client is told to retry.
    def timekeeping_unavailable(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: message }, status: 503 }
        format.html { render file: "public/500.html", status: 503, layout: false, alert: message }
      end
    end

    # The write expected an ownership generation that is no longer current, so
    # it changed nothing. The client reloads and retries against the new owner.
    def render_stale_generation(_exception)
      render json: { errors: I18n.t("errors.stale_generation"), reason: STALE_GENERATION_REASON }, status: 409
    end

    # The answers below come from a forwarded Timekeeping entry write. Each
    # renders a fixed monolith message, never the exception's message or
    # Timekeeping's answer body.

    def render_timekeeping_forbidden(_exception)
      render json: { errors: I18n.t("pundit.default") }, status: 403
    end

    # The entry changed after it was checked, so nothing was written.
    def render_entry_version_conflict(_exception)
      render json: { errors: I18n.t("errors.entry_version_conflict"), reason: VERSION_CONFLICT_REASON }, status: 409
    end

    def render_entry_write_rejected(_exception)
      render json: { errors: I18n.t("errors.entry_write_rejected") }, status: 422
    end

    def invalid_param_value(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: message }, status: 400 }
        format.html { render file: "public/400.html", status: 400, layout: false, alert: message }
      end
    end
end

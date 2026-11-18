# frozen_string_literal: true

# Opens and stops the settle step of a handoff away from Timekeeping
# (docs/architecture/timekeeping-soa.md section 10.5). The transitions and
# their rules for late or repeated calls live in Timekeeping::Admission.
class Timekeeping::Internal::V1::Handoff::SettlingController < Timekeeping::Internal::V1::Handoff::BaseController
  rescue_from ActiveRecord::RecordNotFound, with: :render_admission_missing

  before_action :require_generation

  # Answers whether a settle step is open, read back from the row, because
  # begin_settling! changes nothing when writes are still admitted or the
  # generation was already stopped.
  def settle
    Timekeeping::Admission.begin_settling!(generation:)
    render json: { settling: Timekeeping::Admission.settling?,
                   prepared_operations: InvoiceOperation.where(state: "prepared").count }
  end

  def stop_applying
    Timekeeping::Admission.stop_applying!(generation:)
    render json: {}
  end

  private

    def generation
      json_body["generation"]
    end

    # Refuses before the model is called, so a generation above the bigint
    # range never reaches the database.
    def require_generation
      render_invalid_request unless Timekeeping::Handoff::WireIntegers.generation?(generation)
    end

    def render_admission_missing
      render_reason(:admission_missing)
    end
end

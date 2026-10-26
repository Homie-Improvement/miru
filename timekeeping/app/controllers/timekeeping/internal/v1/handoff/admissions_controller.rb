# frozen_string_literal: true

# Fences and admits entry writes. It only calls Timekeeping::Admission, and
# never answers success when the fence or admit did not happen: a caller that
# read a failed fence as success would go on with a handoff while writes are
# still admitted.
class Timekeeping::Internal::V1::Handoff::AdmissionsController < Timekeeping::Internal::V1::Handoff::BaseController
  # Only these two calls give the errors this meaning: the fence waited past
  # its lock timeout, or the admission row is gone.
  rescue_from ActiveRecord::LockWaitTimeout, with: :render_fence_timeout
  rescue_from ActiveRecord::RecordNotFound, with: :render_admission_missing

  def fence
    Timekeeping::Admission.fence!
    render_generation
  end

  # admit! raises ArgumentError for anything but a positive Integer, a JSON
  # string such as "3" included, before it touches the row.
  def admit
    Timekeeping::Admission.admit!(generation: json_body["generation"])
    render_generation
  rescue ArgumentError
    render_invalid_request
  end

  private

    def render_generation
      render json: { generation: Timekeeping::Admission.current.generation }
    end

    def render_fence_timeout
      render_reason(:fence_timeout)
    end

    def render_admission_missing
      render_reason(:admission_missing)
    end
end

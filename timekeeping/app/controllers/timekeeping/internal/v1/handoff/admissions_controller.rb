# frozen_string_literal: true

# Fences and admits entry writes, and opens and stops the settle step of a
# handoff away from Timekeeping. It only calls Timekeeping::Admission, and
# never answers success when the call did not reach the row: a caller that
# read a failed fence as success would go on with a handoff while writes are
# still admitted.
class Timekeeping::Internal::V1::Handoff::AdmissionsController < Timekeeping::Internal::V1::Handoff::BaseController
  # Only these calls give the errors this meaning: the row lock waited past
  # its timeout, or the admission row is gone.
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

  # The generation is the outgoing one, admitted before the fence. Like
  # admit!, begin_settling! refuses anything but a positive Integer.
  def begin_settling
    Timekeeping::Admission.begin_settling!(generation: json_body["generation"])
    render_settling_state
  rescue ArgumentError
    render_invalid_request
  end

  def stop_applying
    Timekeeping::Admission.stop_applying!(generation: json_body["generation"])
    render_settling_state
  rescue ArgumentError
    render_invalid_request
  end

  private

    def render_generation
      render json: { generation: Timekeeping::Admission.current.generation }
    end

    # begin_settling! ignores a call while writes are admitted or once that
    # generation's step was stopped, and stop_applying! leaves a newer open
    # step alone. Neither raises, so the answer carries the row as it now
    # stands and the caller can tell whether the step opened or stopped.
    def render_settling_state
      admission = Timekeeping::Admission.current
      render json: {
        generation: admission.generation,
        settling_generation: admission.settling_generation,
        settling_stopped_generation: admission.settling_stopped_generation
      }
    end

    def render_fence_timeout
      render_reason(:fence_timeout)
    end

    def render_admission_missing
      render_reason(:admission_missing)
    end
end

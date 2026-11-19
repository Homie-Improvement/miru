# frozen_string_literal: true

# Runs the snapshot relay once and answers whether every outbox snapshot
# through a position has been sent (Timekeeping::Handoff::Drain).
class Timekeeping::Internal::V1::Handoff::DrainsController < Timekeeping::Internal::V1::Handoff::BaseController
  def create
    through = json_body["through"]
    return render_invalid_request unless Timekeeping::Handoff::WireIntegers.position?(through)

    render json: { drained: Timekeeping::Handoff::Drain.call(through:) }
  end
end

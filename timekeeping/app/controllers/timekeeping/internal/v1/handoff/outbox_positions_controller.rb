# frozen_string_literal: true

# The highest outbox_snapshots position, which the handoff drains through
# before it freezes (docs/architecture/timekeeping-soa.md section 10.5).
class Timekeeping::Internal::V1::Handoff::OutboxPositionsController < Timekeeping::Internal::V1::Handoff::BaseController
  def show
    render json: { outbox_position: service_store.highest_outbox_position }
  end
end

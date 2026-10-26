# frozen_string_literal: true

# The projection endpoint the Timekeeping relay delivers entry snapshots to
# (docs/architecture/timekeeping-soa.md section 5.4,
# contracts/timekeeping/entry_snapshots.yml). The base controller refuses any
# credential but the Timekeeping service token before this action runs.
class Internal::V1::Timekeeping::EntrySnapshotsController < Internal::V1::BaseController
  def create
    result = ::Timekeeping::ProjectionConsumer.call(batch: batch, idempotency_key: request.headers["Idempotency-Key"])
    render json: result.body, status: result.status
  end

  private

    # The raw body, not params: the consumer checks the contract's exact key
    # lists, which Rails parameter wrapping would extend with its own key.
    # A body that is not JSON reaches the consumer as nil and is refused there.
    def batch
      JSON.parse(request.raw_post)
    rescue JSON::ParserError
      nil
    end
end

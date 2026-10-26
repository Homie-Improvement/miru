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

  # The deepest batch Timekeeping can send: an entry body it admitted under
  # JSON's default limit of 100 levels, carried three levels down (batch,
  # snapshots list, item). The relay delivers in order and never skips a row,
  # so a stored snapshot this parser refused would hold back every later one.
  BATCH_MAX_NESTING = 103

  private

    # The raw body, not params: the consumer checks the contract's exact key
    # lists, which Rails parameter wrapping would extend with its own key.
    # A body that is not JSON reaches the consumer as nil and is refused there.
    # Decimals are read as BigDecimal, so metadata finer than a Float reaches
    # the projection with every digit.
    def batch
      JSON.parse(request.raw_post, max_nesting: BATCH_MAX_NESTING, decimal_class: BigDecimal)
    rescue JSON::ParserError
      nil
    end
end

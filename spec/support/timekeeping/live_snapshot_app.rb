# frozen_string_literal: true

require "rack"

# The monolith's entry-snapshot endpoint as a live Timekeeping instance's
# relay sees it during a regression run: a Rack app, served by
# TimekeepingLiveInstance on its own loopback listener, that hands each batch
# to the projection consumer in this process. Rows therefore reach
# timesheet_entries only through Timekeeping::ProjectionConsumer, never through
# a spec copying them in.
#
# It keeps the consumer's last answer for each company, so a delivery that
# did not finish can be reported with the refusal that stopped it.
class TimekeepingLiveSnapshotApp
  # Set once the live instance has started and drawn its token. Until then
  # every request is refused.
  attr_accessor :service_token

  def initialize
    @answers = {}
    @answers_lock = Mutex.new
  end

  def call(env)
    request = Rack::Request.new(env)
    return respond(401, "reason" => "unauthorized") unless authorized?(request)
    unless request.post? && request.path_info == TimekeepingRelay::HttpEndpoint::DELIVER_PATH
      return respond(404, "reason" => "not_found")
    end

    batch = parse_batch(request.body.read)
    # Served on the listener's own threads, which must hand their database
    # connection back after each request.
    answer = ActiveRecord::Base.connection_pool.with_connection do
      TimekeepingHandoffOutboxRelay::ConsumerEndpoint.new.deliver(batch, idempotency_key: request.get_header("HTTP_IDEMPOTENCY_KEY"))
    end
    remember(batch, answer)
    respond(answer.status, answer.body)
  end

  # The consumer's last answer to a batch that held a snapshot of company_id,
  # or nil when no such batch arrived.
  def answer_for(company_id)
    @answers_lock.synchronize { @answers[company_id] }
  end

  private

    def authorized?(request)
      service_token.present? && request.get_header("HTTP_AUTHORIZATION") == "Bearer #{service_token}"
    end

    # Parsed as Internal::V1::Timekeeping::EntrySnapshotsController parses it:
    # decimals as BigDecimal so no hour or amount is rounded, and a body that
    # is not JSON reaches the consumer as nil to be refused there.
    def parse_batch(raw)
      JSON.parse(raw, max_nesting: Internal::V1::Timekeeping::EntrySnapshotsController::BATCH_MAX_NESTING,
                      decimal_class: BigDecimal)
    rescue JSON::ParserError
      nil
    end

    # The live relay picks outbox rows by position, not by company, so one
    # batch can carry several companies; the answer is kept under each.
    def remember(batch, answer)
      snapshots = batch.is_a?(Hash) ? batch["snapshots"] : nil
      return unless snapshots.is_a?(Array)

      company_ids = snapshots.filter_map { |snapshot| snapshot_company_id(snapshot) }.uniq
      @answers_lock.synchronize { company_ids.each { |company_id| @answers[company_id] = answer } }
    end

    # A malformed snapshot is the consumer's to refuse; it names no company here.
    def snapshot_company_id(snapshot)
      entry = snapshot["entry"] if snapshot.is_a?(Hash)
      entry["company_id"] if entry.is_a?(Hash)
    end

    def respond(status, body)
      [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
    end
end

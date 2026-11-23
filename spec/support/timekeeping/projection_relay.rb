# frozen_string_literal: true

# Delivers the entries the owning store wrote into timesheet_entries the way
# production does, so specs that read the projection after a write read rows
# the real relay produced instead of rows a spec copied in, which would hide a
# snapshot missing from the outbox:
#
# - rollback: Timekeeping::RelayJob reads each company's unsent rows of the
#   prepared store's outbox and posts them to the projection consumer;
# - timekeeping, while TimekeepingRegressionAdapter runs a live app: the live
#   app's own relay is asked to drain its outbox to the adapter's snapshot app,
#   which hands each batch to the projection consumer in this process.
module TimekeepingProjectionRelay
  # Raised when a row of the company stays unsent after the relay ran, such as
  # a batch the consumer refused, so the example fails with the consumer's
  # answer instead of reading as a projected row that is simply missing.
  class Undelivered < StandardError; end

  # Calls the projection consumer in process and keeps each company's last
  # answer, so a refusal is reported for the company it belongs to. The
  # prepared store's relay never mixes companies in one batch, so the first
  # snapshot names it.
  class CompanyAnswers
    attr_reader :answers

    def initialize
      @consumer = TimekeepingHandoffOutboxRelay::ConsumerEndpoint.new
      @answers = {}
    end

    def deliver(batch, idempotency_key:)
      company_id = batch.fetch("snapshots").first&.dig("entry", "company_id")
      @consumer.deliver(batch, idempotency_key:).tap { |answer| @answers[company_id] = answer }
    end
  end

  # How long a live drain may keep answering false before the delivery counts
  # as failed. A drain also answers false while another run holds the relay
  # lock, so a single false is retried rather than reported.
  LIVE_DELIVERY_DEADLINE_SECONDS = 30
  LIVE_DRAIN_RETRY_SECONDS = 0.1
  MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

  # Drains the live outbox through the highest position it holds now, retrying
  # until the drain answers true. On the deadline it raises Undelivered with
  # the consumer's last answer for company_id. store answers
  # highest_outbox_position and drain(through:), as
  # Timekeeping::Handoff::TimekeepingStore does; answers answers
  # answer_for(company_id), as TimekeepingLiveSnapshotApp does. started_at is
  # the clock reading the deadline counts from.
  def self.deliver_live_snapshots!(store:, answers:, company_id:, deadline_seconds: LIVE_DELIVERY_DEADLINE_SECONDS,
                                   clock: MONOTONIC_CLOCK, started_at: clock.call)
    through = store.highest_outbox_position
    loop do
      return nil if store.drain(through:)
      break if clock.call - started_at >= deadline_seconds

      sleep LIVE_DRAIN_RETRY_SECONDS
    end

    answer = answers.answer_for(company_id)
    consumer = answer ? "consumer answered #{answer.status.inspect} #{answer.body.inspect}" : "the consumer was never called"
    raise Undelivered, "live outbox snapshots through position #{through} stayed unsent for company #{company_id} " \
                       "after #{deadline_seconds} s; #{consumer}"
  end

  # Delivers the company's rows when the prepared store owns the entries, or
  # when a live Timekeeping app owns them, and does nothing in any other
  # state, where writes never reach an outbox this run can drain.
  #
  # In rollback only the given company's unsent rows are checked, because the
  # prepared store's relay delivers each company on its own. The live drain
  # covers every unsent row through the service's highest outbox position,
  # whatever its company, so another company's refused snapshot also fails
  # the wait; there the company only picks which consumer answer is reported.
  def relay_local_entries_to_projection(company)
    live = TimekeepingRegressionAdapter.current
    # A live wait's deadline counts from this call, so the time spent reading
    # the ownership row below is inside it.
    started_at = MONOTONIC_CLOCK.call if live
    owner = Timekeeping::EntryOwner.for(TimekeepingOwnership.current)
    return relay_prepared_entries_to_projection(company) if owner == :prepared
    return relay_live_entries_to_projection(company, live, started_at) if owner == :timekeeping && live

    nil
  end

  private

    def relay_prepared_entries_to_projection(company)
      endpoint = CompanyAnswers.new
      allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
      Timekeeping::RelayJob.perform_now

      unsent = Timekeeping::LocalOutboxEntry.where(company_id: company.id, sent_at: nil).count
      return nil if unsent.zero?

      answer = endpoint.answers[company.id]
      raise Undelivered, "#{unsent} outbox row(s) of company #{company.id} stayed unsent; " \
                         "consumer answered #{answer&.status.inspect} #{answer&.body.inspect}"
    end

    # The drain is the harness's own call, not a request the monolith
    # forwarded, so it stays out of the forwarded request log.
    def relay_live_entries_to_projection(company, live, started_at)
      store = Timekeeping::Handoff::TimekeepingStore.new(base_url: live.base_url, token: live.service_token)
      ForwardedTimekeepingRequestLog.unrecorded do
        TimekeepingProjectionRelay.deliver_live_snapshots!(store:, answers: TimekeepingRegressionAdapter.snapshot_app,
                                                           company_id: company.id, started_at:)
      end
    end
end

RSpec.configure do |config|
  config.include TimekeepingProjectionRelay
end

# frozen_string_literal: true

# Delivers the prepared store's entry outbox into timesheet_entries the way a
# rollback does live: Timekeeping::RelayJob reads each company's unsent outbox
# rows and posts them to the projection consumer. Specs that read the
# projection after a write call it, so a rollback example reads rows the real
# relay produced instead of rows a spec copied in, which would hide a snapshot
# missing from the outbox.
module TimekeepingProjectionRelay
  # Raised when a row of the company stays unsent after the relay ran, such as
  # a batch the consumer refused, so the example fails with the consumer's
  # answer instead of reading as a projected row that is simply missing.
  class Undelivered < StandardError; end

  # Runs the relay when the prepared store owns the entries, and does nothing
  # in any other state, where writes never reach the local outbox. Only the
  # given company's rows are checked, because the relay delivers each company
  # on its own and one company's refusal does not stop another's delivery.
  def relay_local_entries_to_projection(company)
    return nil unless Timekeeping::EntryOwner.for(TimekeepingOwnership.current) == :prepared

    endpoint = CompanyAnswers.new
    allow(Timekeeping::LocalSnapshotEndpoint).to receive(:configured).and_return(endpoint)
    Timekeeping::RelayJob.perform_now

    unsent = Timekeeping::LocalOutboxEntry.where(company_id: company.id, sent_at: nil).count
    return nil if unsent.zero?

    answer = endpoint.answers[company.id]
    raise Undelivered, "#{unsent} outbox row(s) of company #{company.id} stayed unsent; " \
                       "consumer answered #{answer&.status.inspect} #{answer&.body.inspect}"
  end

  # Calls the projection consumer in process and keeps each company's last
  # answer, so a refusal is reported for the company it belongs to. The relay
  # never mixes companies in one batch, so the first snapshot names it.
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
end

RSpec.configure do |config|
  config.include TimekeepingProjectionRelay
end

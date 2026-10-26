# frozen_string_literal: true

module TimekeepingRelay
  # Delivers an outbox to the projection endpoint in outbox_position order,
  # and marks a row sent only after a 200, so delivery is at least once
  # (docs/architecture/timekeeping-soa.md section 5.4).
  class Relay
    # contracts/timekeeping/entry_snapshots.yml schema_version.
    SCHEMA_VERSION = 1
    NEVER_PAUSED = -> { false }

    # source is a TimekeepingRelay::OutboxSource. endpoint answers
    # #deliver(batch, idempotency_key:) with a TimekeepingRelay::Response and
    # holds the target URL and credential, so the relay never sees either.
    # paused is checked before every POST.
    def initialize(source:, endpoint:, paused: NEVER_PAUSED)
      @source = source
      @endpoint = endpoint
      @paused = paused
    end

    # Sends batches of at most limit rows until the outbox has no unsent row,
    # an answer is not a delivery, or the relay is paused. Any failed answer
    # ends the run: sending a later batch past a refused one would reach the
    # consumer out of order. The next run starts again at the first unsent row.
    def deliver(limit:)
      raise ArgumentError, "limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?

      sent = 0
      last_position = nil
      loop do
        rows = @source.unsent_after(last_position || 0, limit)
        break if rows.empty? || @paused.call

        batch = batch_for(rows)
        response = @endpoint.deliver(batch, idempotency_key: IdempotencyKey.for(batch))
        break unless response.delivered?(rows.size)

        # The exact positions delivered, never a range: positions have gaps,
        # and a row below last_position can still be unsent.
        positions = rows.map { |row| row.fetch("outbox_position") }
        @source.mark_sent(positions)
        sent += positions.size
        last_position = positions.last
      end
      { sent:, last_position: }
    end

    private

      def batch_for(rows)
        snapshots = rows.map do |row|
          { "generation" => row.fetch("generation"), "outbox_position" => row.fetch("outbox_position"),
            "entry" => row.fetch("entry") }
        end
        { "schema_version" => SCHEMA_VERSION, "snapshots" => snapshots }
      end
  end
end

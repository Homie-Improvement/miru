# frozen_string_literal: true

module Timekeeping
  # The snapshot relay's view of this service's own outbox_snapshots table
  # (TimekeepingRelay::OutboxSource). The entry offered for each row is cut to
  # OutboxFields::ENTRY_FIELDS, so the relay's own enqueued_at and sent_at
  # columns never reach a payload. Rows are read as stored and never rebuilt
  # from entries, so a resend carries the same values under the same generation.
  class RelayOutboxSource
    include TimekeepingRelay::OutboxSource

    def unsent_after(position, limit)
      OutboxSnapshot.where(sent_at: nil).where("outbox_position > ?", position)
                    .order(:outbox_position).limit(limit).map { |row| relay_row(row) }
    end

    # Marks by outbox_position only: one entry can have several snapshot rows,
    # and marking by entry id would hide a later, still unsent one. A position
    # already marked keeps its first sent_at.
    def mark_sent(positions)
      OutboxSnapshot.where(outbox_position: positions, sent_at: nil).update_all(sent_at: Time.current)
      nil
    end

    private

      def relay_row(row)
        attributes = row.attributes
        {
          "generation" => attributes.fetch("generation"),
          "outbox_position" => attributes.fetch("outbox_position"),
          "entry" => attributes.slice(*OutboxFields::ENTRY_FIELDS).transform_values { |value| wire_value(value) }
        }
      end

      # JSON.generate writes a timestamp as Time#to_s ("2026-03-02 09:00:00 UTC"),
      # which drops its microseconds. ISO 8601 in UTC with microseconds keeps
      # created_at, updated_at and discarded_at equal to the stored entry's.
      def wire_value(value)
        value.is_a?(Time) ? value.utc.iso8601(6) : value
      end
  end
end

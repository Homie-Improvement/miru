# frozen_string_literal: true

module Timekeeping
  # The snapshot relay's view of this service's own outbox_snapshots table
  # (TimekeepingRelay::OutboxSource). The entry offered for each row is cut to
  # OutboxFields::ENTRY_FIELDS, so the relay's own enqueued_at and sent_at
  # columns never reach a payload. Rows are read as stored and never rebuilt
  # from entries, so a resend carries the same values under the same generation.
  class RelayOutboxSource
    include TimekeepingRelay::OutboxSource

    # The jsonb entry fields. Active Record's jsonb cast reads every decimal as
    # a Float, which rounds one finer than a double, so these are parsed from
    # the stored text with exact decimals instead.
    JSON_FIELDS = %w[source_metadata proof_metadata].freeze

    # Rows of the held generation are a first cutover's correction snapshots,
    # offered only once the flip admits that generation (Admission.hold_generation!).
    def unsent_after(position, limit)
      rows = OutboxSnapshot.where(sent_at: nil).where("outbox_position > ?", position)
      held = Admission.held_generation
      rows = rows.where.not(generation: held) unless held.nil?
      rows.order(:outbox_position).limit(limit).map { |row| relay_row(row) }
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
        entry = attributes.slice(*OutboxFields::ENTRY_FIELDS).transform_values { |value| wire_value(value) }
        JSON_FIELDS.each { |field| entry[field] = exact_json(row.read_attribute_before_type_cast(field)) }
        {
          "generation" => attributes.fetch("generation"),
          "outbox_position" => attributes.fetch("outbox_position"),
          "entry" => entry
        }
      end

      def exact_json(text)
        text.nil? ? nil : JSON.parse(text, decimal_class: BigDecimal)
      end

      # JSON.generate writes a timestamp as Time#to_s ("2026-03-02 09:00:00 UTC"),
      # which drops its microseconds. ISO 8601 in UTC with microseconds keeps
      # created_at, updated_at and discarded_at equal to the stored entry's.
      def wire_value(value)
        value.is_a?(Time) ? value.utc.iso8601(6) : value
      end
  end
end

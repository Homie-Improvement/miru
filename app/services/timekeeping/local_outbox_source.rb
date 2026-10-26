# frozen_string_literal: true

module Timekeeping
  # The snapshot relay's view of one company's rows in the prepared monolith's
  # outbox, entry_outbox_items (TimekeepingRelay::OutboxSource). Positions come
  # from one sequence shared by every company, so both queries filter by
  # company_id: a mark by position alone could hide another company's rows
  # before they were delivered.
  class LocalOutboxSource
    include TimekeepingRelay::OutboxSource

    def initialize(company_id:)
      @company_id = company_id
    end

    def unsent_after(position, limit)
      unsent.where("outbox_position > ?", position).order(:outbox_position).limit(limit)
            .map { |row| relay_row(row) }
    end

    # Marks by outbox_position only: one entry can have several snapshot rows,
    # and marking by entry id would hide a later, still unsent one. A position
    # already marked keeps its first sent_at.
    def mark_sent(positions)
      unsent.where(outbox_position: positions).update_all(sent_at: Time.current)
      nil
    end

    private

      attr_reader :company_id

      def unsent
        LocalOutboxEntry.where(company_id:, sent_at: nil)
      end

      def relay_row(row)
        {
          "generation" => row.generation,
          "outbox_position" => row.outbox_position,
          "entry" => entry(row.read_attribute_before_type_cast("payload"))
        }
      end

      # Parsed from the stored text with exact decimals, because Active Record's
      # jsonb cast reads every decimal as a Float and rounds metadata numbers
      # finer than a double. Timestamps are stored as ISO 8601 strings with
      # microseconds, so they pass through as written. The entry is cut to the
      # contract fields, so a key a later writer adds is never posted. duration
      # is held in the payload as the jsonb number of the shortest decimal of the
      # written Float, so converting it back to a Float gives the same bits.
      def entry(payload_text)
        payload = JSON.parse(payload_text, decimal_class: BigDecimal).slice(*SnapshotBatch::ENTRY_FIELDS)
        duration = payload["duration"]
        payload["duration"] = duration.to_f if duration.is_a?(BigDecimal)
        payload
      end
  end
end

# frozen_string_literal: true

module TimekeepingRelaySpec
  # An in-memory TimekeepingRelay::OutboxSource, so the relay is tested without
  # any database. It records every mark_sent call.
  class MemoryOutboxSource
    include TimekeepingRelay::OutboxSource

    attr_reader :mark_calls

    def initialize(rows)
      @rows = rows
      @sent = []
      @mark_calls = []
    end

    def unsent_after(position, limit)
      @rows.reject { |row| @sent.include?(row["outbox_position"]) }
           .select { |row| row["outbox_position"] > position }
           .sort_by { |row| row["outbox_position"] }
           .first(limit)
    end

    def mark_sent(positions)
      @mark_calls << positions
      @sent |= positions
      nil
    end

    def self.row(position)
      { "generation" => 1, "outbox_position" => position,
        "entry" => { "id" => position, "company_id" => 1, "version" => 1 } }
    end
  end
end

# frozen_string_literal: true

module TimekeepingRelaySpec
  # An in-memory TimekeepingRelay::OutboxSource, so the relay is tested without
  # any database. It records every successful mark_sent call in mark_calls, and
  # every mark lost through fail_next_mark! in lost_marks.
  class MemoryOutboxSource
    include TimekeepingRelay::OutboxSource

    attr_reader :mark_calls, :lost_marks, :sent_positions

    def initialize(rows)
      @rows = rows.dup
      @sent_positions = []
      @mark_calls = []
      @lost_marks = []
      @fail_next_mark = false
    end

    def unsent_after(position, limit)
      @rows.reject { |row| @sent_positions.include?(row["outbox_position"]) }
           .select { |row| row["outbox_position"] > position }
           .sort_by { |row| row["outbox_position"] }
           .first(limit)
    end

    def mark_sent(positions)
      if @fail_next_mark
        @fail_next_mark = false
        @lost_marks << positions
        raise IOError, "outbox database went away"
      end

      @mark_calls << positions
      @sent_positions |= positions
      nil
    end

    # Makes the next mark_sent fail after the endpoint answered 200, as when
    # the outbox database goes away between the answer and the mark. The rows
    # stay unsent, so the next run resends them.
    def fail_next_mark!
      @fail_next_mark = true
      nil
    end

    # Adds a row committed after the source was built, which can sit below
    # positions already sent.
    def add(row)
      @rows << row
    end

    def self.row(position, id: position, generation: 1)
      { "generation" => generation, "outbox_position" => position,
        "entry" => { "id" => id, "company_id" => 1, "version" => 1 } }
    end
  end
end

# frozen_string_literal: true

module TimekeepingRelay
  # The interface a relay reads an outbox through. Each application implements
  # it over its own database, so a relay never reads another application's
  # database.
  module OutboxSource
    # Returns at most limit unsent rows whose outbox_position is above
    # position, in ascending outbox_position order. Each row is a Hash with the
    # string keys "generation", "outbox_position" and "entry", where "entry"
    # already holds only the contract's entry fields. Positions may have gaps.
    def unsent_after(position, limit)
      raise NotImplementedError, "#{self.class} must implement unsent_after(position, limit)"
    end

    # Marks exactly these positions sent. Positions already marked are left
    # as they are, so a repeated call is harmless.
    def mark_sent(positions)
      raise NotImplementedError, "#{self.class} must implement mark_sent(positions)"
    end
  end
end

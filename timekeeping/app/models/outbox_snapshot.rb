# frozen_string_literal: true

# The id column holds the entry's id, so the row is keyed by its position.
class OutboxSnapshot < ApplicationRecord
  self.primary_key = "outbox_position"
end

# frozen_string_literal: true

# The id column holds the entry's id, so the row is keyed by its position.
class OutboxSnapshot < ApplicationRecord
  self.primary_key = "outbox_position"

  # The one key every writer takes just before its outbox inserts and holds
  # until commit, so outbox positions commit in the order they were drawn.
  INSERT_LOCK_KEY = 2_026_034_001

  # Takes INSERT_LOCK_KEY for the rest of the calling transaction.
  def self.lock_for_insert!
    connection.execute(sanitize_sql_array(["SELECT pg_advisory_xact_lock(?)", INSERT_LOCK_KEY]))
  end
end

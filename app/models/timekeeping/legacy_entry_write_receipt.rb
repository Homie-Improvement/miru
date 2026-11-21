# frozen_string_literal: true

module Timekeeping
  # The stored answer to one timesheet entry update or delete made while the
  # legacy store owns entries, scoped to its company, actor kind, actor,
  # operation and Idempotency-Key. A retry of that write replays the answer
  # instead of writing the entry again.
  class LegacyEntryWriteReceipt < ApplicationRecord
    RETENTION = LegacyCreateReceipt::RETENTION

    scope :expired, -> { where(expires_at: ..Time.current) }
  end
end

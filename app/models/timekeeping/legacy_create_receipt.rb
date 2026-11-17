# frozen_string_literal: true

module Timekeeping
  # The stored answer to one timesheet entry create made while the legacy
  # store owns entries, scoped to its company, actor kind, actor and
  # Idempotency-Key. A retry of that create replays the answer instead of
  # writing the entry again. The handoff never reads or copies these rows.
  class LegacyCreateReceipt < ApplicationRecord
    # The entry API's receipt retention (contracts/timekeeping/idempotency.yml
    # retention_hours), which covers the client's retry window.
    RETENTION = SnapshotDeliveryReceipts::RETENTION

    scope :expired, -> { where(expires_at: ..Time.current) }
  end
end

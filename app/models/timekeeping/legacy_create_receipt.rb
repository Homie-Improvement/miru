# frozen_string_literal: true

module Timekeeping
  # The stored answer to one timesheet entry create made while the legacy
  # store owns entries, scoped to its company, actor kind, actor and
  # Idempotency-Key. A retry of that create replays the answer instead of
  # writing the entry again. forwarded_body is the body a forwarded create of
  # the same request would send to Timekeeping, kept so the receipt can still
  # answer a retry that arrives after the first cutover.
  class LegacyCreateReceipt < ApplicationRecord
    # The entry API's receipt retention (contracts/timekeeping/idempotency.yml
    # retention_hours), which covers the client's retry window.
    RETENTION = SnapshotDeliveryReceipts::RETENTION

    scope :expired, -> { where(expires_at: ..Time.current) }
  end
end

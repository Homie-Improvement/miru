# frozen_string_literal: true

module Timekeeping
  class LocalOwner
    # The stored answer of one service command (commit, abort, mark_billed or
    # detach_entries), keyed by company, service name, operation and key, as
    # Timekeeping's service_idempotency_receipts is. The table has no other
    # model in the monolith.
    class ServiceReceipt < ApplicationRecord
      self.table_name = "service_idempotency_receipts"
    end
  end
end

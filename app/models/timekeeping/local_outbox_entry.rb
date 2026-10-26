# frozen_string_literal: true

module Timekeeping
  # One entry snapshot in the prepared monolith's outbox
  # (docs/architecture/timekeeping-soa.md section 10.1). payload holds the
  # contract snapshot fields of one entry; outbox_position comes from the
  # table's sequence, and the relay sets sent_at once the projection has
  # accepted the row.
  class LocalOutboxEntry < ApplicationRecord
    self.table_name = "entry_outbox_items"
    self.primary_key = "outbox_position"
  end
end

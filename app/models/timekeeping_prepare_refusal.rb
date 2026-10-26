# frozen_string_literal: true

# A prepare the reservation port refused for one company
# (docs/architecture/timekeeping-soa.md section 11.3). reason is one conflict
# reason from the refused outcome; the alert task counts only
# on_another_invoice.
class TimekeepingPrepareRefusal < ApplicationRecord
  validates :company_id, presence: true
end

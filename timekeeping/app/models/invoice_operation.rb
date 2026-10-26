# frozen_string_literal: true

# One prepare, commit or abort of an invoice's reservations, identified by
# (company_id, actor_name, operation_id). Prepare stores the desired entry set
# and disposition here, so commit applies exactly what prepare accepted.
class InvoiceOperation < ApplicationRecord
end

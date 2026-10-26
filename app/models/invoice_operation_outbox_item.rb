# frozen_string_literal: true

# A commit or abort of an invoice operation waiting for delivery to the
# reservation service (docs/architecture/timekeeping-soa.md section 9.2).
class InvoiceOperationOutboxItem < ApplicationRecord
  KINDS = %w[commit abort].freeze

  validates :company_id, :operation_id, presence: true
  validates :kind, inclusion: { in: KINDS }
end

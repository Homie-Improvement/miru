# frozen_string_literal: true

# The monolith's durable record of an invoice save that changes which entries
# the invoice holds (docs/architecture/timekeeping-soa.md section 9.2). It has
# no association to Invoice on purpose: the intent must outlive a deleted
# invoice.
class InvoiceOperationIntent < ApplicationRecord
  STATES = %w[pending committed failed].freeze

  validates :company_id, :invoice_id, :operation_id, :generation, presence: true
  validates :state, inclusion: { in: STATES }
  validates :disposition, inclusion: { in: Invoices::ReservationRequest::DISPOSITIONS }
end

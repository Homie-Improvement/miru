# frozen_string_literal: true

# The monolith's durable record of which entries an invoice holds, and with
# which disposition (docs/architecture/timekeeping-soa.md section 9). It has no
# association to Invoice on purpose: the holding must outlive a destroyed
# invoice, so its entries stay accounted for.
class InvoiceEntryHolding < ApplicationRecord
  validates :company_id, :invoice_id, presence: true
  validates :disposition, inclusion: { in: Invoices::ReservationRequest::DISPOSITIONS }
end

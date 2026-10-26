# frozen_string_literal: true

# A commit or abort of an invoice operation waiting for delivery to the
# reservation service (docs/architecture/timekeeping-soa.md section 9.2).
class InvoiceOperationOutboxItem < ApplicationRecord
  KINDS = %w[commit abort].freeze

  validates :company_id, :operation_id, presence: true
  validates :kind, inclusion: { in: KINDS }

  # Writes a row whose payload holds every field of the reservation request,
  # so delivery can resend it without reading the invoice. Returns its id.
  def self.record!(kind:, company_id:, invoice_id:, operation_id:, generation:, disposition:, desired_entry_ids:)
    payload = { company_id:, invoice_id:, operation_id:, generation:, disposition:, desired_entry_ids: }
    create!(company_id:, invoice_id:, operation_id:, kind:, payload:).id
  end
end

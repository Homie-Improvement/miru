# frozen_string_literal: true

class InvoiceLineItemTimeEntry < ApplicationRecord
  belongs_to :invoice_line_item
  belongs_to :timesheet_entry

  validates :timesheet_entry_id, uniqueness: { scope: :invoice_line_item_id }
  validate :timesheet_entry_in_invoice_company

  before_save :register_reservation_change
  before_destroy :register_reservation_change

  private

    def register_reservation_change
      invoice = invoice_line_item&.invoice
      Invoices::ReservationBoundary.register(invoice) if invoice
    end

    # Compares the stored company_id, so an entry with no company never matches,
    # and reports the same not found error a line item gives for a missing id.
    def timesheet_entry_in_invoice_company
      return if invoice_line_item&.invoice.blank? || timesheet_entry.blank?
      return if timesheet_entry.company_id == invoice_line_item.invoice.company_id

      errors.add(:timesheet_entry, :not_found)
    end
end

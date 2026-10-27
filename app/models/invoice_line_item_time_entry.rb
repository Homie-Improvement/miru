# frozen_string_literal: true

class InvoiceLineItemTimeEntry < ApplicationRecord
  include BillingFenced

  belongs_to :invoice_line_item
  belongs_to :timesheet_entry

  validates :timesheet_entry_id, uniqueness: { scope: :invoice_line_item_id }
  validate :timesheet_entry_in_invoice_company

  before_save :register_reservation_change
  before_destroy :register_reservation_change

  private

    # A link moved to another line can change the entries of two invoices,
    # so the invoice it leaves registers too, before the move is written.
    def register_reservation_change
      invoices = [invoice_line_item&.invoice]
      if will_save_change_to_invoice_line_item_id? && invoice_line_item_id_in_database
        invoices << InvoiceLineItem.find_by(id: invoice_line_item_id_in_database)&.invoice
      end
      invoices.compact.uniq.each { |invoice| Invoices::ReservationBoundary.register(invoice) }
    end

    # Compares the stored company_id, so an entry with no company never matches,
    # and reports the same not found error a line item gives for a missing id.
    def timesheet_entry_in_invoice_company
      return if invoice_line_item&.invoice.blank? || timesheet_entry.blank?
      return if timesheet_entry.company_id == invoice_line_item.invoice.company_id

      errors.add(:timesheet_entry, :not_found)
    end
end

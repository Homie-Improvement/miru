# frozen_string_literal: true

class InvoiceLineItemTimeEntry < ApplicationRecord
  include BillingFenced

  belongs_to :invoice_line_item
  # Optional because, once Timekeeping owns the entries, a link may name an
  # entry the lagging projection does not hold yet. The reservation boundary
  # then checks the id at commit against Timekeeping's prepare answer.
  belongs_to :timesheet_entry, optional: true

  validates :timesheet_entry, presence: { message: :required }, if: :entries_checked_by_projection?
  validates :timesheet_entry_id, presence: true, unless: :entries_checked_by_projection?
  validates :timesheet_entry_id, uniqueness: { scope: :invoice_line_item_id }
  validate :timesheet_entry_in_invoice_company, if: :entries_checked_by_projection?

  before_save :register_reservation_change
  before_destroy :register_reservation_change

  private

    def entries_checked_by_projection?
      Invoices::EntryReferenceCheck.for(TimekeepingOwnership.current) == :projection
    end

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
    # No database key checks timesheet_entry_id, so the stored row is read, not
    # a cached entry object, and key-share locked so it cannot be deleted before
    # this save commits, as InvoiceLineItem does for its direct entry.
    def timesheet_entry_in_invoice_company
      return if invoice_line_item&.invoice.blank? || timesheet_entry.blank?

      stored_entry = TimesheetEntry.where(id: timesheet_entry_id, company_id: invoice_line_item.invoice.company_id)
      return if stored_entry.lock("FOR KEY SHARE").exists?

      errors.add(:timesheet_entry, :not_found)
    end
end

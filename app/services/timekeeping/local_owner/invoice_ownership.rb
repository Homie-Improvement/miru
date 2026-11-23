# frozen_string_literal: true

module Timekeeping
  class LocalOwner
    # Whether an invoice belongs to a company, decided before the prepared
    # monolith's prepare or mark-billed reads or writes anything. It mirrors the
    # Timekeeping service's Timekeeping::InvoiceOwnership, reading the
    # monolith's own rule (OwnedInvoices) where the service asks the reference
    # endpoint.
    #
    # A hard-deleted invoice has no row left, but its reservations keep their
    # owner, so an id the company's own invoice_operations hold still counts.
    # That fallback is read only when no other company has an invoice row or an
    # invoice_operation_intents row with the id: invoice ids are one primary key
    # across companies, so either row proves another owner (the intent commits
    # before a new invoice row is visible), and an operation row a prepare stored before
    # ownership was checked must not keep admitting that company's invoice.
    # Every read is scoped to the company or to the invoice id alone, so one
    # company's rows never admit another company's request.
    module InvoiceOwnership
      module_function

      def owned?(company_id:, invoice_id:)
        return true if OwnedInvoices.ids(company_id:, invoice_ids: [invoice_id]).include?(invoice_id)
        return false if Invoice.where(id: invoice_id).where.not(company_id:).exists?
        return false if InvoiceOperationIntent.where(invoice_id:).where.not(company_id:).exists?

        ReservationOperations::InvoiceOperation.exists?(company_id:, invoice_id:)
      end
    end
  end
end

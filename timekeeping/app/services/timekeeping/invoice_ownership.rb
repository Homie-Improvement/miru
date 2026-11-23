# frozen_string_literal: true

module Timekeeping
  # Whether an invoice belongs to a company, decided before a prepare or a
  # mark-billed writes anything. Timekeeping stores no invoices: the monolith
  # owns them and lists the company's invoices on its reference endpoint. A
  # hard-deleted invoice is no longer listed there, but its reservations keep
  # their owner, so an invoice the company's own invoice_operations already
  # hold counts as the company's without asking the monolith. Every read is
  # scoped to the company and made fresh, so one company's rows or answers
  # never decide another company's request.
  module InvoiceOwnership
    module_function

    # Raises ReferenceClient::Unavailable when the monolith cannot answer, so
    # the caller refuses the request rather than guess either way.
    def owned?(company_id:, invoice_id:)
      InvoiceOperation.exists?(company_id:, invoice_id:) ||
        ReferenceClient.configured.owned_invoice_ids(company_id:, invoice_ids: [invoice_id]).include?(invoice_id)
    end
  end
end

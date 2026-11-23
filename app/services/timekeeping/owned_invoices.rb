# frozen_string_literal: true

module Timekeeping
  # Which invoice ids belong to a company, the one rule the reference endpoint
  # (ReferenceFacts) and the monolith's own Timekeeping writer both read.
  #
  # An id is the company's when one of its invoices has it, discarded ones
  # included, because a discarded invoice still owns its reservations. An id
  # the company only holds as an invoice_operation_intents row, in any state,
  # counts too: the invoice save commits that intent on its own connection
  # before it asks Timekeeping to prepare, while the new invoice row is not yet
  # committed and so not visible to another connection, and the abort of a
  # rolled-back save replays prepare with the intent already failed. Another
  # company's invoice or intent is left out exactly like an id no invoice has,
  # so the answer reveals nothing about other companies.
  module OwnedInvoices
    module_function

    # The requested ids the company owns, sorted and without duplicates.
    def ids(company_id:, invoice_ids:)
      requested = Array(invoice_ids).map(&:to_i).uniq
      return [] if requested.empty?

      invoices = Invoice.where(company_id:, id: requested).pluck(:id)
      intents = InvoiceOperationIntent.where(company_id:, invoice_id: requested).distinct.pluck(:invoice_id)
      (invoices + intents).uniq.sort
    end
  end
end

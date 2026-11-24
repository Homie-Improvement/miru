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
  # so ids reveals nothing about other companies.
  #
  # held_by_others is the other side of the same rows: the requested ids that
  # another company holds as an invoice (discarded ones included) or as an
  # intent. Invoice ids are one primary key across companies, so either row
  # proves another owner, and an ownership check must refuse such an id before
  # it trusts the company's own invoice_operations rows. It answers ids only,
  # never which company holds them.
  module OwnedInvoices
    module_function

    # The requested ids the company owns, sorted and without duplicates.
    def ids(company_id:, invoice_ids:)
      requested = normalized(invoice_ids)
      return [] if requested.empty?

      invoices = Invoice.where(company_id:, id: requested).pluck(:id)
      intents = InvoiceOperationIntent.where(company_id:, invoice_id: requested).distinct.pluck(:invoice_id)
      (invoices + intents).uniq.sort
    end

    # The requested ids another company holds, sorted and without duplicates.
    def held_by_others(company_id:, invoice_ids:)
      requested = normalized(invoice_ids)
      return [] if requested.empty?

      invoices = Invoice.where(id: requested).where.not(company_id:).pluck(:id)
      intents = InvoiceOperationIntent.where(invoice_id: requested).where.not(company_id:).distinct.pluck(:invoice_id)
      (invoices + intents).uniq.sort
    end

    def normalized(invoice_ids)
      Array(invoice_ids).map(&:to_i).uniq
    end
    private_class_method :normalized
  end
end

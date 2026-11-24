# frozen_string_literal: true

module Timekeeping
  # Whether an invoice belongs to a company, decided before a prepare or a
  # mark-billed writes anything. Timekeeping stores no invoices: the monolith
  # owns them and its reference endpoint says, for the requested id, whether
  # the company holds it and whether another company holds it as an invoice
  # or an in-flight intent.
  #
  # A hard-deleted invoice is no longer held by anyone, but its reservations
  # keep their owner, so an id the company's own invoice_operations hold still
  # counts. That fallback is read only after the monolith says no other
  # company holds the id: invoice ids are one primary key across companies,
  # and an operation row a prepare stored before ownership was checked must
  # not keep admitting another company's invoice. This is the same order as
  # the monolith's Timekeeping::LocalOwner::InvoiceOwnership.
  #
  # Every read is scoped to the company and made fresh, so one company's rows
  # or answers never decide another company's request.
  module InvoiceOwnership
    module_function

    # Raises ReferenceClient::Unavailable when the monolith cannot answer, so
    # the caller refuses the request rather than guess either way.
    def owned?(company_id:, invoice_id:)
      holders = ReferenceClient.configured.invoice_holders(company_id:, invoice_ids: [invoice_id])
      return true if holders.owned_ids.include?(invoice_id)
      return false if holders.foreign_ids.include?(invoice_id)

      InvoiceOperation.exists?(company_id:, invoice_id:)
    end
  end
end

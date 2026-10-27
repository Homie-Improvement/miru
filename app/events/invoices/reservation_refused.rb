# frozen_string_literal: true

module Invoices
  # An invoice save refused because an entry it adds is not free, for example
  # because another kept invoice already holds it. Sent once, from the refused
  # save, so an operator can count refusals per company.
  #
  # The payload holds only the refused invoice's own ids and the reason; it
  # never names the invoice that holds the entry, so the signal cannot expose
  # another invoice.
  module ReservationRefused
    NAME = "invoices.reservation_refused"

    def self.notify(company_id:, invoice_id:, reason:)
      Rails.event.notify(NAME, company_id:, invoice_id:, reason:)
    end
  end
end

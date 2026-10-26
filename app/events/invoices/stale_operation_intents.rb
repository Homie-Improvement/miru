# frozen_string_literal: true

module Invoices
  # One company's invoice operation intents that have stayed pending past the
  # stale threshold. Sent once per company so an operator can see which
  # workspace's saves are not converging; it never combines companies.
  #
  # Reported under a fixed string name with a flat payload, because the
  # recovery worker has no request context and so no actor to report.
  module StaleOperationIntents
    NAME = "invoices.stale_operation_intents"

    def self.notify(company_id:, count:, oldest_created_at:)
      Rails.event.notify(NAME, company_id:, count:, oldest_created_at:)
    end
  end
end

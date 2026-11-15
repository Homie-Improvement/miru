# frozen_string_literal: true

module Invoices
  # One invoice operation outbox row that the Timekeeping service refused
  # because the save was made against a stale ownership generation. The row
  # is kept but no longer delivered or recovered, so an operator must act.
  #
  # Reported under a fixed string name with a flat payload, because delivery
  # runs with no request context and so no actor to report. The payload names
  # the row only; it never carries the request body or a token.
  module UndeliverableOperation
    NAME = "invoices.undeliverable_operation"

    def self.notify(company_id:, operation_id:, kind:)
      Rails.event.notify(NAME, company_id:, operation_id:, kind:)
    end
  end
end

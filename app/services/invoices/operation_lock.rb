# frozen_string_literal: true

module Invoices
  # The one advisory lock that serializes a save of an invoice, its failure
  # write and the recovery sweep. They must all build the same key, or
  # recovery could fail an intent whose save is still running.
  module OperationLock
    module_function

    # Takes a transaction-scoped lock on (company_id, invoice_id) on the given
    # connection. Refuses a missing part, which would make unrelated saves
    # share one key.
    def acquire!(connection, company_id:, invoice_id:)
      raise ArgumentError, "company_id is required" if company_id.nil?
      raise ArgumentError, "invoice_id is required" if invoice_id.nil?

      connection.execute(ActiveRecord::Base.sanitize_sql_array(
        ["SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", key(company_id:, invoice_id:)]
      ))
      nil
    end

    def key(company_id:, invoice_id:)
      "invoice_operation:#{company_id}:#{invoice_id}"
    end
  end
end

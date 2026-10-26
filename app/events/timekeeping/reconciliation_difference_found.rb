# frozen_string_literal: true

module Timekeeping
  # One difference that handoff reconciliation found between the loaded
  # checkpoint and the frozen source. The payload names the company, check,
  # row and field but carries no row values, because event history is
  # readable across every workspace.
  class ReconciliationDifferenceFound < ApplicationEvent
    # listed: whether the pre-flight listed this difference as a correction
    # for the same company, so a listed difference is still signalled.
    def initialize(difference, listed:, actor: Current.user)
      @listed = listed
      super(difference, actor:)
    end

    private

      def event_data
        {
          company_id: record.company_id,
          check: record.check,
          table: record.table,
          row_key: record.row_key,
          field: record.field,
          reason: record.reason,
          listed: @listed
        }
      end
  end
end

# frozen_string_literal: true

module Timekeeping
  # One changed value between two financial snapshots of a company. The
  # payload names the changed row and field but leaves out the old and new
  # money values, because event history is readable across every workspace.
  class FinancialSnapshotChanged < ApplicationEvent
    private

      def event_data
        {
          company_id: record.company_id,
          kind: record.kind,
          record_id: record.record_id,
          field: record.field
        }
      end
  end
end

# frozen_string_literal: true

require_relative "contract"

module TimekeepingContract
  # Decides the outcome of a replayed invoice save when prepare answers 200
  # with a terminal state, from the save_reconciliation table in
  # contracts/timekeeping/reservations.yml. The invoice boundary lane runs the
  # same examples against its real save.
  class FakeReconciler
    POLICIES = {
      # The table row for the pair, or the fallback when no row matches.
      outcome: lambda do |table, remote_state:, intent_state:|
        table.fetch("rows").find { |row| row["remote_state"] == remote_state && row["intent_state"] == intent_state } ||
          table.fetch("fallback")
      end
    }.freeze

    def initialize(policies: POLICIES)
      @policies = POLICIES.merge(policies)
      @table = TimekeepingContract.load(:reservations).fetch("save_reconciliation")
    end

    def call(remote_state:, intent_state:)
      @policies[:outcome].call(@table, remote_state:, intent_state:).slice("outcome", "retryable", "changed")
    end
  end
end

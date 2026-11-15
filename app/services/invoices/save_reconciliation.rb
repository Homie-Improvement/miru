# frozen_string_literal: true

module Invoices
  # Decides how a Timekeeping invoice operation ends from the service's
  # operation state and the stored intent's state, using the
  # save_reconciliation table in contracts/timekeeping/reservations.yml.
  # The contract file is the only written form of the table, so this module
  # reads it rather than restating it. A pair the table does not list,
  # including a nil state, takes the table's retryable fallback: an HTTP 200
  # answer on its own never counts as success.
  module SaveReconciliation
    TABLE = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/reservations.yml"))
      .fetch("save_reconciliation").freeze
    RESULT_KEYS = %w[outcome retryable changed].freeze

    def self.call(remote_state:, intent_state:)
      row = TABLE.fetch("rows").find do |candidate|
        candidate["remote_state"] == remote_state && candidate["intent_state"] == intent_state
      end
      (row || TABLE.fetch("fallback")).slice(*RESULT_KEYS)
    end
  end
end

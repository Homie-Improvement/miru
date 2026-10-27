# frozen_string_literal: true

require "yaml"

module Invoices
  # Decides how a commit or abort outbox row ends from the operation's remote
  # state and its intent's state, using the save_reconciliation table in
  # contracts/timekeeping/reservations.yml. Only the pairs the table lists
  # settle a row; every other pair, including a remote state the table does
  # not name, takes the table's retryable fallback. An HTTP answer alone
  # therefore never settles a row.
  module SaveReconciliation
    TABLE = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/reservations.yml"))
      .fetch("save_reconciliation").freeze
    ANSWER_FIELDS = %w[outcome retryable changed].freeze

    module_function

    # Returns the table's answer, such as
    # { "outcome" => "existing_success", "retryable" => false, "changed" => false }.
    def call(remote_state:, intent_state:)
      row = TABLE.fetch("rows").find do |candidate|
        candidate.fetch("remote_state") == remote_state && candidate.fetch("intent_state") == intent_state
      end
      (row || TABLE.fetch("fallback")).slice(*ANSWER_FIELDS)
    end
  end
end

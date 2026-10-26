# frozen_string_literal: true

module Timekeeping
  # The columns of an outbox_snapshots row: contracts/timekeeping/
  # entry_snapshots.yml entry_fields, plus generation and outbox_position, plus
  # the relay's own bookkeeping. The list is written out here because the app
  # deploys without the contracts directory;
  # spec/services/timekeeping/outbox_fields_spec.rb compares it with the
  # contract. Rows carry ids only, never a name, email or token.
  module OutboxFields
    ENTRY_FIELDS = %w[
      id project_id user_id agent_id work_date duration note bill_status
      review_status locked source source_metadata external_run_id
      external_session_id proof_url proof_metadata discarded_at created_at
      updated_at company_id version
    ].freeze
    ROW_FIELDS = (ENTRY_FIELDS + %w[generation outbox_position]).freeze
    # When the row was written and when the projection endpoint accepted it.
    # The database fills both, and neither ever travels in a snapshot.
    RELAY_FIELDS = %w[enqueued_at sent_at].freeze

    module_function

    # The entry must be read with Timekeeping::EntriesQuery::RESERVED selected:
    # locked is the reservation flag the API shows, because the stored
    # entries.locked column is never kept current. outbox_position is left to
    # its sequence.
    def row(entry, generation:)
      entry.attributes.slice(*ENTRY_FIELDS).merge("locked" => entry.reserved, "generation" => generation)
    end
  end
end

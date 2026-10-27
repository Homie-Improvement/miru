# frozen_string_literal: true

module Timekeeping
  # The entry body of contracts/timekeeping/entry_api.yml response.entry_fields,
  # in contract order. The list is written out here because the app deploys
  # without the contracts directory; a spec compares it with the contract.
  module EntryPresenter
    STORED_FIELDS = %w[
      id company_id version project_id user_id work_date duration note
      bill_status review_status source source_metadata agent_id proof_url proof_metadata
      external_run_id external_session_id
    ].freeze

    module_function

    # The entry must come from Timekeeping::EntriesQuery, which selects the
    # reserved flag that locked is read from.
    def call(entry)
      entry.attributes.slice(*STORED_FIELDS).merge("locked" => entry.reserved)
    end
  end
end

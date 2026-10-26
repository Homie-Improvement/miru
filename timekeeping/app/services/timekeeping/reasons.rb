# frozen_string_literal: true

module Timekeeping
  # The HTTP status for every reason a route can answer with. The service
  # deploys without the contracts directory, so the statuses from
  # contracts/timekeeping/entry_api.yml, idempotency.yml and reservations.yml
  # are written out here; spec/services/timekeeping/reasons_spec.rb compares
  # them with the YAML. reference_unavailable, idempotency_key_required and invalid_request
  # (a write body that is not JSON or holds a value of the wrong shape) are
  # this service's own answers, not yet listed in the contract. So are the
  # internal handoff routes' handoff_refused (a store refused to export, load
  # or write corrections), fence_timeout (a fence waited past its lock
  # timeout; retryable) and admission_missing (the admission row is gone).
  # unpublishable_entry is also the service's own: a write would republish a
  # stored entry holding a value the snapshot rules refuse.
  module Reasons
    STATUS = {
      unauthorized: 401,
      forbidden: 403,
      not_found: 404,
      stale_generation: 409,
      version_conflict: 409,
      credential_in_body: 422,
      idempotency_key_reused: 422,
      idempotency_key_required: 422,
      reference_unavailable: 503,
      invalid_request: 400,
      handoff_refused: 409,
      fence_timeout: 503,
      admission_missing: 409,
      conflict: 409,
      unresolved_operation: 409,
      unpublishable_entry: 409
    }.freeze

    module_function

    # Raises KeyError for a reason missing from STATUS, so a misspelled reason
    # fails loudly instead of being sent to Rack as an unknown status symbol.
    def status(reason)
      STATUS.fetch(reason.to_sym)
    end
  end
end

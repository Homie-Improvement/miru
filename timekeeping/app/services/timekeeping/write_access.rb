# frozen_string_literal: true

module Timekeeping
  # Decides, before any query or reference read runs, whether a write request
  # may go on. It follows ReadAccess except for a token whose signature
  # verified but whose exp has passed: a write answers that with the retryable
  # :reference_unavailable, because an expired token cannot supply the facts a
  # write needs. The expired caller carries no verified company, so the answer
  # does not depend on the path company and reveals nothing about it.
  module WriteAccess
    module_function

    def decide(identity, path_company_id:)
      return :reference_unavailable if identity.status == :expired

      ReadAccess.decide(identity, path_company_id:)
    end
  end
end

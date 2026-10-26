# frozen_string_literal: true

module Timekeeping
  # Decides, before any query or reference read runs, whether a write request
  # may go on. It follows ReadAccess except for a token whose signature
  # verified but whose exp has passed: a write answers that with the retryable
  # :reference_unavailable, because an expired token cannot supply the facts a
  # write needs. The expired caller carries no verified company, so the answer
  # does not depend on the path company and reveals nothing about it.
  #
  # A token minted for a delegated read can carry a raised role (an admin
  # whose older role is employee), and the writer takes the role from the
  # token, so only a write token may write. A token signed without a purpose
  # carries the user's primary role, as every token did before purposes
  # existed, so it may still write. Any other purpose answers :forbidden.
  module WriteAccess
    WRITE_PURPOSES = [nil, "write"].freeze

    module_function

    def decide(identity, path_company_id:)
      return :reference_unavailable if identity.status == :expired

      decision = ReadAccess.decide(identity, path_company_id:)
      return decision unless decision == :allowed
      return :forbidden unless WRITE_PURPOSES.include?(identity.purpose)

      :allowed
    end
  end
end

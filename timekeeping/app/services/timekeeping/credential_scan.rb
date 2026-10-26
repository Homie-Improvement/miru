# frozen_string_literal: true

module Timekeeping
  # The credential scan lives in the shared rules gem, so the monolith's local
  # owner refuses the same bodies this service refuses. Callers here pass
  # bearer:, held: and public_key:.
  CredentialScan = TimekeepingRules::CredentialScan
end

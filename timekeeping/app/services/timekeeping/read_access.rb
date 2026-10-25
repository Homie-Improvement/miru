# frozen_string_literal: true

module Timekeeping
  # Decides, before any query runs, whether a read request may go on. Only a
  # verified user token may read entries. A path company other than the
  # token's answers :not_found, the same as a missing id, so a caller cannot
  # tell whether another company exists.
  module ReadAccess
    module_function

    def decide(identity, path_company_id:)
      return :unauthorized unless identity.kind == :user && identity.status == :verified
      return :not_found unless path_company_id.to_s == identity.company_id.to_s

      :allowed
    end
  end
end

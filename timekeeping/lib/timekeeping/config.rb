# frozen_string_literal: true

require_relative "environment"

module Timekeeping
  # Settings derived from Timekeeping::Environment. Each is worked out when
  # asked for, never cached, so a spec can swap the environment for one example.
  module Config
    CREDENTIAL_SEPARATOR = ","

    module_function

    # Every credential the service holds: its own service token and each entry
    # of TIMEKEEPING_SERVICE_CREDENTIALS. None of them may reach a stored row or
    # a log line. Blank entries are dropped so an empty string never matches.
    def service_credentials
      extra = Environment.service_credentials.to_s.split(CREDENTIAL_SEPARATOR).map(&:strip)
      [Environment.service_token.to_s, *extra].reject(&:empty?).uniq
    end
  end

  def self.config
    Config
  end
end

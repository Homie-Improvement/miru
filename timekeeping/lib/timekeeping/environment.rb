# frozen_string_literal: true

module Timekeeping
  # The only settings the service reads from its process environment. Each is
  # read when asked for, never cached, so no key lives in a checked-in file and
  # a spec can swap a value for one example.
  module Environment
    DATABASE_URL = "TIMEKEEPING_DATABASE_URL"
    TOKEN_PUBLIC_KEY = "TIMEKEEPING_TOKEN_PUBLIC_KEY"
    SERVICE_TOKEN = "TIMEKEEPING_SERVICE_TOKEN"
    MONOLITH_REFERENCE_URL = "MONOLITH_REFERENCE_URL"
    KEYS = [DATABASE_URL, TOKEN_PUBLIC_KEY, SERVICE_TOKEN, MONOLITH_REFERENCE_URL].freeze

    module_function

    # Raises KeyError when unset: the service has no other database to use.
    def database_url
      ENV.fetch(DATABASE_URL)
    end

    def token_public_key
      ENV.fetch(TOKEN_PUBLIC_KEY, nil)
    end

    def service_token
      ENV.fetch(SERVICE_TOKEN, nil)
    end

    def monolith_reference_url
      ENV.fetch(MONOLITH_REFERENCE_URL, nil)
    end
  end
end

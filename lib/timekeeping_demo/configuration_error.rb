# frozen_string_literal: true

module TimekeepingDemo
  # Raised when the demo runtime cannot be started safely from the given
  # process table and environment.
  class ConfigurationError < StandardError; end
end

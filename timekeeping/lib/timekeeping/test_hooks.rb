# frozen_string_literal: true

require "fileutils"

module Timekeeping
  # Controls the integration tests use to hold snapshot delivery. Anyone able
  # to pause the relay could stop every company's entries reaching the
  # monolith, so config/application.rb requires this file only in the test
  # environment or when TIMEKEEPING_TEST_HOOKS=1, and the routes and RelayJob
  # use it only when it is loaded.
  module TestHooks
    # A file rather than a variable: a pause set through a request must also
    # stop a relay running in the separate worker process.
    RELAY_PAUSE_DIRECTORY = File.expand_path("../../tmp", __dir__)

    module_function

    def pause_relay!
      FileUtils.mkdir_p(RELAY_PAUSE_DIRECTORY)
      FileUtils.touch(relay_pause_file)
    end

    def resume_relay!
      FileUtils.rm_f(relay_pause_file)
    end

    def relay_paused?
      File.exist?(relay_pause_file)
    end

    # One file per Rails environment, so a pause left by a process in another
    # environment on the same checkout does not hold this one's relay.
    def relay_pause_file
      File.join(RELAY_PAUSE_DIRECTORY, "relay_paused.#{Rails.env}")
    end
  end
end

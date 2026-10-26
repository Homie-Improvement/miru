# frozen_string_literal: true

require "fileutils"

module Timekeeping
  # Controls the integration tests use to hold snapshot delivery and to slow
  # entry writes. Anyone able to pause the relay could stop every company's
  # entries reaching the monolith, and anyone able to set a write delay could
  # slow every company's writes, so config/application.rb requires this file
  # only in the test environment or when TIMEKEEPING_TEST_HOOKS=1, and the
  # routes, RelayJob and Timekeeping::WriteMetricsRecording use it only when it
  # is loaded.
  module TestHooks
    # Files rather than variables: a pause or a delay set through a request
    # must also reach the relay worker and every other server process.
    HOOK_DIRECTORY = File.expand_path("../../tmp", __dir__)

    module_function

    def pause_relay!
      FileUtils.mkdir_p(HOOK_DIRECTORY)
      FileUtils.touch(relay_pause_file)
    end

    def resume_relay!
      FileUtils.rm_f(relay_pause_file)
    end

    def relay_paused?
      File.exist?(relay_pause_file)
    end

    # Every entry write waits this many milliseconds before it runs, inside the
    # time the write metrics measure, so a test can raise the p95 latency.
    def delay_writes!(milliseconds)
      FileUtils.mkdir_p(HOOK_DIRECTORY)
      File.write(write_delay_file, Integer(milliseconds).to_s)
    end

    def clear_write_delay!
      FileUtils.rm_f(write_delay_file)
    end

    # The delay in seconds, 0.0 when none is set.
    def write_delay_seconds
      Integer(File.read(write_delay_file), exception: false).to_i / 1000.0
    rescue Errno::ENOENT
      0.0
    end

    # One file per Rails environment, so a hook left by a process in another
    # environment on the same checkout does not act on this one.
    def relay_pause_file
      File.join(HOOK_DIRECTORY, "relay_paused.#{Rails.env}")
    end

    def write_delay_file
      File.join(HOOK_DIRECTORY, "write_delay_ms.#{Rails.env}")
    end
  end
end

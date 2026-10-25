# frozen_string_literal: true

module Timekeeping
  # Records each entry write in Timekeeping::WriteMetrics. Used as an
  # around_action declared before the write access check, so it also sees a
  # write that access refuses, one whose body fails to parse and one that
  # raises after its transaction rolled back. The record runs once the answer
  # is rendered and the write's transaction has closed, so a rollback never
  # removes it.
  #
  # The company is identity.signed_company_id, from a token whose signature
  # verified; a request without one records nothing, so no caller can add
  # counts under a company it names only in the path.
  module WriteMetricsRecording
    extend ActiveSupport::Concern

    private

      def record_write_metric
        started = monotonic_ms
        outcome = :write
        yield
        outcome = WriteMetrics.outcome_for(response.status)
      ensure
        company_id = identity.signed_company_id
        record_write(company_id, outcome, monotonic_ms - started) if company_id
      end

      # A backstop for a database fault in the metric write: the answer is
      # already decided, and a lost count must not replace it or hide the
      # action's own exception.
      def record_write(company_id, outcome, latency_ms)
        WriteMetrics.new(clock: -> { Time.current }).record(company_id:, outcome:, latency_ms:)
      rescue StandardError => e
        logger.warn("write metric not recorded: #{e.class}")
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      end
  end
end

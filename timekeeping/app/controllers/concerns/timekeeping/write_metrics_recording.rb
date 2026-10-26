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
        reason = nil
        yield
        outcome = WriteMetrics.outcome_for(response.status)
        reason = answered_reason
      ensure
        company_id = identity.signed_company_id
        record_write(company_id, outcome, reason, monotonic_ms - started) if company_id
      end

      # A backstop for a database fault in the metric write: the answer is
      # already decided, and a lost count must not replace it or hide the
      # action's own exception.
      def record_write(company_id, outcome, reason, latency_ms)
        WriteMetrics.new(clock: -> { Time.current }).record(company_id:, outcome:, latency_ms:, reason:)
      rescue StandardError => e
        logger.warn("write metric not recorded: #{e.class}")
      end

      # The reason in a 409 refusal body ({"reason": ...}). Only a 409 is read,
      # because stale_generation shares that status with version_conflict and
      # only the body tells them apart; every other answer needs no reason.
      def answered_reason
        return unless response.status == Reasons.status(:stale_generation)

        body = JSON.parse(response.body)
        body["reason"] if body.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      end
  end
end

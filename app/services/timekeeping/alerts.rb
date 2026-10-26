# frozen_string_literal: true

module Timekeeping
  # Decides which section 11.3 alerts (docs/architecture/timekeeping-soa.md)
  # hold for a set of signals. It is pure: it reads no database, HTTP or clock,
  # so the caller passes the current time as signals[:now].
  #
  # signals is a Hash. A key that is missing or nil means the signal has no
  # source, and its row raises no alert: a missing count must never read as a
  # healthy zero, and the caller reports it as unavailable instead.
  #
  #   now:                        Time
  #   owner:                      "monolith" or "timekeeping" (TimekeepingOwnership#owner)
  #   outbox_lag_by_owner:        { owner => [{ "company_id", "oldest_unsent_age_seconds" }] }
  #   pending_intents:            [{ company_id:, oldest_created_at: Time }]
  #   ownership_moving:           { started_at: Time, planned_pause_seconds: Numeric }
  #   stale_generation_refusals:  [{ company_id:, handoff_step:, count: }]
  #   prepare_refusals:           [{ company_id:, count: }]
  #   reconciliation_differences: [{ company_id:, count: }]
  #   financial_snapshot_changes: [{ company_id:, count: }]
  #   write_metrics:              the GET /internal/v1/metrics body of the Timekeeping service
  #
  # Every row fires only when its value is strictly over its limit, as each
  # section 11.3 threshold is worded "over" or "any".
  module Alerts
    Alert = Data.define(:name, :company_id, :value, :threshold)

    # limit nil means the limit arrives with the signal (the planned write pause).
    Row = Data.define(:name, :measure, :limit)

    # One measured value, with the company it belongs to (nil for a signal that
    # is not per company) and, for rows whose limit comes with the signal, that limit.
    Measurement = Data.define(:company_id, :value, :limit) do
      def initialize(company_id:, value:, limit: nil) = super
    end

    REFERENCE_UNAVAILABLE_LIMIT = Rational(1, 100)
    P95_SHARE = Rational(95, 100)

    # The section 11.3 table, in its own order.
    TABLE = [
      Row.new(name: "outbox_lag", measure: :outbox_lag_seconds, limit: 5 * 60),
      Row.new(name: "pending_invoice_operation_intent", measure: :pending_intent_age_seconds, limit: 10 * 60),
      Row.new(name: "ownership_moving", measure: :ownership_moving_seconds, limit: nil),
      Row.new(name: "stale_generation", measure: :stale_generations_outside_handoff, limit: 0),
      Row.new(name: "reference_unavailable_rate", measure: :reference_unavailable_rate, limit: REFERENCE_UNAVAILABLE_LIMIT),
      Row.new(name: "prepare_refusal", measure: :prepare_refusal_count, limit: 0),
      Row.new(name: "reconciliation_difference", measure: :reconciliation_difference_count, limit: 0),
      Row.new(name: "financial_snapshot_change", measure: :financial_snapshot_change_count, limit: 0),
      Row.new(name: "entry_write_p95_latency", measure: :entry_write_p95_ms, limit: 300)
    ].freeze

    module_function

    def evaluate(signals)
      TABLE.flat_map do |row|
        Measures.public_send(row.measure, signals).filter_map do |measurement|
          limit = measurement.limit || row.limit
          next unless measurement.value > limit

          Alert.new(name: row.name, company_id: measurement.company_id, value: measurement.value, threshold: limit)
        end
      end
    end

    # Each measure reads one signal and returns the Measurements it holds, or
    # none when the signal is absent.
    module Measures
      module_function

      # Only the current owner's outbox is judged: the other side's outbox is
      # not delivering anything the readers depend on.
      def outbox_lag_seconds(signals)
        rows = signals[:outbox_lag_by_owner]&.fetch(signals[:owner], nil)
        Array(rows).map do |row|
          Measurement.new(company_id: row.fetch("company_id"), value: row.fetch("oldest_unsent_age_seconds"))
        end
      end

      def pending_intent_age_seconds(signals)
        Array(signals[:pending_intents]).map do |intent|
          Measurement.new(company_id: intent.fetch(:company_id), value: signals.fetch(:now) - intent.fetch(:oldest_created_at))
        end
      end

      # The billing write fence is global, so its alert names no company.
      def ownership_moving_seconds(signals)
        moving = signals[:ownership_moving]
        return [] unless moving

        [Measurement.new(company_id: nil, value: signals.fetch(:now) - moving.fetch(:started_at),
                         limit: moving.fetch(:planned_pause_seconds))]
      end

      def stale_generations_outside_handoff(signals)
        outside = Array(signals[:stale_generation_refusals]).select { |refusal| refusal[:handoff_step].nil? }
        outside.group_by { |refusal| refusal.fetch(:company_id) }.map do |company_id, refusals|
          Measurement.new(company_id:, value: refusals.sum { |refusal| refusal.fetch(:count) })
        end
      end

      def prepare_refusal_count(signals) = company_counts(signals[:prepare_refusals])
      def reconciliation_difference_count(signals) = company_counts(signals[:reconciliation_differences])
      def financial_snapshot_change_count(signals) = company_counts(signals[:financial_snapshot_changes])

      # Divides by writes + reference_unavailable: Timekeeping counts a refused
      # write only under reference_unavailable, never under writes.
      def reference_unavailable_rate(signals)
        completed_windows(signals).filter_map do |company_id, window|
          refused = window.fetch("reference_unavailable")
          total = window.fetch("writes") + refused
          Measurement.new(company_id:, value: Rational(refused, total)) if total.positive?
        end
      end

      # The smallest bucket bound that holds 95% of the window's requests. When
      # only the overflow bucket reaches 95%, the p95 is above every bound.
      def entry_write_p95_ms(signals)
        body = signals[:write_metrics]
        completed_windows(signals).filter_map do |company_id, window|
          p95 = p95_bound(window.fetch("latency_ms_buckets"), body.fetch("latency_bucket_bounds_ms"),
                          body.fetch("overflow_bucket"))
          Measurement.new(company_id:, value: p95) if p95
        end
      end

      def company_counts(counts)
        Array(counts).map { |entry| Measurement.new(company_id: entry.fetch(:company_id), value: entry.fetch(:count)) }
      end

      # [company_id, window] for each company's latest window that has run its
      # full length and ended within the last window length. A window still in
      # progress is never judged, so one failure seconds after a window opens
      # cannot fire, and a newer window cannot hide a completed one.
      def completed_windows(signals)
        body = signals[:write_metrics]
        return [] unless body

        now = signals.fetch(:now)
        length = body.fetch("window_seconds")
        body.fetch("companies").filter_map do |company|
          window = company.fetch("windows")
                          .select { |candidate| completed_recently?(candidate, now, length) }
                          .max_by { |candidate| Time.iso8601(candidate.fetch("window_start")) }
          [company.fetch("company_id"), window] if window
        end
      end

      def completed_recently?(window, now, length)
        ends_at = Time.iso8601(window.fetch("window_start")) + length
        ends_at <= now && ends_at > now - length
      end

      def p95_bound(buckets, bounds, overflow_key)
        total = buckets.values.sum
        return nil unless total.positive?

        cumulative = 0
        bounds.each do |bound|
          cumulative += buckets.fetch(bound.to_s, 0)
          return bound if cumulative >= total * P95_SHARE
        end
        buckets.key?(overflow_key) ? Float::INFINITY : nil
      end
    end
  end
end

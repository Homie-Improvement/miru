# frozen_string_literal: true

module Timekeeping
  # The alert table of docs/architecture/timekeeping-soa.md section 11.3, and
  # the pure evaluator over it. evaluate reads only the Signals it is given:
  # no database, HTTP, environment or clock, so every threshold can be tested
  # at its exact boundary.
  #
  # A signal that is nil has no source yet. Its rules neither fire nor raise,
  # and unsourced names it, so a missing input is never read as a quiet one.
  module Alerts
    # Every input a rule reads. The *_by_company values map company_id to a
    # number. write_pause_seconds is one number, because a handoff pauses
    # writes for every company at once. write_metrics is the validated
    # GET /internal/v1/metrics body.
    Signals = Data.define(
      :now,
      :outbox_lag_seconds_by_company,
      :pending_intent_age_seconds_by_company,
      :write_pause_seconds,
      :stale_generation_outside_handoff_by_company,
      :write_metrics,
      :prepare_refusals_by_company,
      :unexplained_reconciliation_differences_by_company,
      :financial_snapshot_changes_by_company
    )

    # company_id is nil for an alert about every company, such as a write pause.
    Alert = Data.define(:name, :company_id, :value, :threshold) do
      def log_line
        "timekeeping alert=#{name} company_id=#{company_id || "all"} value=#{value} threshold=#{threshold}"
      end
    end

    WINDOW_SECONDS = 300
    # The rate rule reads the latest completed window; the p95 rule reads every
    # window that started within this many seconds, the current one included.
    RECENT_WINDOW_SECONDS = 600
    P95_SHARE = Rational(95, 100)

    # One row per alert. measure names how a signal becomes values per
    # company; comparison names how a value is held against threshold.
    # "Over" in section 11.3 is strictly greater, so a value exactly at a
    # threshold stays quiet. The design document gives no number for the
    # planned write pause, so 300 seconds is this table's own choice.
    RULES = [
      { name: :outbox_lag, signal: :outbox_lag_seconds_by_company, measure: :per_company,
        comparison: :over, threshold: 300 },
      { name: :pending_invoice_operation_intent, signal: :pending_intent_age_seconds_by_company, measure: :per_company,
        comparison: :over, threshold: 600 },
      { name: :ownership_moving, signal: :write_pause_seconds, measure: :all_companies,
        comparison: :over, threshold: 300 },
      { name: :stale_generation, signal: :stale_generation_outside_handoff_by_company, measure: :per_company,
        comparison: :any, threshold: 1 },
      { name: :reference_unavailable, signal: :write_metrics, measure: :completed_window_rate,
        comparison: :over, threshold: Rational(1, 100) },
      { name: :prepare_refusal, signal: :prepare_refusals_by_company, measure: :per_company,
        comparison: :any, threshold: 1 },
      { name: :unexplained_reconciliation_difference, signal: :unexplained_reconciliation_differences_by_company,
        measure: :per_company, comparison: :any, threshold: 1 },
      { name: :financial_snapshot_change, signal: :financial_snapshot_changes_by_company, measure: :per_company,
        comparison: :any, threshold: 1 },
      { name: :entry_write_p95_latency, signal: :write_metrics, measure: :recent_window_p95,
        comparison: :over, threshold: 300 }
    ].map(&:freeze).freeze

    # :any is "count at least threshold"; :over is strictly greater.
    COMPARISONS = {
      over: ->(value, threshold) { value > threshold },
      any: ->(value, threshold) { value >= threshold }
    }.freeze

    module_function

    def evaluate(signals)
      RULES.flat_map do |rule|
        signal = signals.public_send(rule[:signal])
        next [] if signal.nil?

        values_by_company(rule[:measure], signal, signals.now).filter_map do |company_id, value|
          next unless COMPARISONS.fetch(rule[:comparison]).call(value, rule[:threshold])

          Alert.new(name: rule[:name], company_id:, value:, threshold: rule[:threshold])
        end
      end
    end

    # The signals the rules read that have no source in this run.
    def unsourced(signals)
      RULES.map { |rule| rule[:signal] }.uniq.select { |signal| signals.public_send(signal).nil? }
    end

    # [[company_id, value]] for one rule. A company appears at most once,
    # with its worst value.
    def values_by_company(measure, signal, now)
      case measure
      when :per_company then signal.to_a
      when :all_companies then [[nil, signal]]
      when :completed_window_rate then worst_window_values(signal, now) { |window| completed_rate(window, now) }
      when :recent_window_p95 then worst_window_values(signal, now) { |window| recent_p95(window, now, signal) }
      else raise ArgumentError, "unknown alert measure: #{measure.inspect}"
      end
    end

    # Each company's windows are decided on their own counts, never pooled
    # with another company's.
    def worst_window_values(metrics, now, &window_value)
      metrics.fetch("companies").filter_map do |company|
        values = company.fetch("windows").filter_map(&window_value)
        [company.fetch("company_id"), values.max] if values.any?
      end
    end

    # "Over 1% of writes for 5 minutes": only the latest window that has run
    # its full five minutes counts, so one early failure in a fresh window
    # never fires. The two counts never overlap, so the total is their sum.
    def completed_rate(window, now)
      started = window_start(window)
      return unless started + WINDOW_SECONDS <= now && started + RECENT_WINDOW_SECONDS > now

      total = window.fetch("writes") + window.fetch("reference_unavailable")
      Rational(window.fetch("reference_unavailable"), total) if total.positive?
    end

    # The smallest bucket bound that holds 95% of the window's requests. The
    # bounds come from the body, which owns them. The overflow bucket has no
    # upper bound, so it reads as infinite.
    def recent_p95(window, now, metrics)
      return unless window_start(window) > now - RECENT_WINDOW_SECONDS

      buckets = window.fetch("latency_ms_buckets")
      total = buckets.values.sum
      return if total.zero?

      bounds = metrics.fetch("latency_bucket_bounds_ms").map { |bound| [bound.to_s, bound] }
      bounds << [metrics.fetch("overflow_bucket"), Float::INFINITY]
      counted = 0
      bounds.each do |key, bound|
        counted += buckets.fetch(key, 0)
        return bound if counted >= total * P95_SHARE
      end
      nil
    end

    def window_start(window)
      Time.iso8601(window.fetch("window_start"))
    end
  end
end

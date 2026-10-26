# frozen_string_literal: true

module Timekeeping
  # Gathers the signals Timekeeping::Alerts.evaluate reads, from the monolith's
  # own records and from the Timekeeping service's metrics endpoint.
  #
  # A signal with no source is listed in unavailable and left out of signals,
  # never set to zero, because a zero would read as healthy. Four signals have
  # no producer in this repository yet, so they are always unavailable. A
  # failed metrics read makes the metrics-based signals unavailable too, and
  # sets metrics_error, so the caller can still report the monolith-side
  # alerts and then fail.
  module AlertSignals
    # A refusal stays countable for two runs of a task started every 5 minutes.
    STALE_GENERATION_LOOKBACK = 10.minutes

    # Named as the Timekeeping::Alerts rows they would feed.
    NO_SOURCE = %w[ownership_moving prepare_refusal reconciliation_difference financial_snapshot_change].freeze
    METRICS_SIGNALS = %w[reference_unavailable_rate entry_write_p95_latency].freeze
    OUTBOX_LAG = "outbox_lag"

    module_function

    # Returns { signals:, unavailable: [signal names], metrics_error: String or nil }.
    def gather(metrics_client:, now:)
      metrics, metrics_error = read_metrics(metrics_client)
      owner = TimekeepingOwnership.current.owner
      signals = {
        now:,
        owner:,
        pending_intents: pending_intents,
        stale_generation_refusals: stale_generation_refusals(now),
        write_metrics: metrics,
        outbox_lag_by_owner: outbox_lag_by_owner(metrics)
      }.compact

      { signals:, unavailable: unavailable(metrics, owner), metrics_error: }
    end

    def read_metrics(metrics_client)
      [metrics_client.fetch, nil]
    rescue MetricsClient::Error => error
      [nil, error.message]
    end

    def unavailable(metrics, owner)
      missing = NO_SOURCE.dup
      missing.concat(METRICS_SIGNALS) unless metrics
      missing << OUTBOX_LAG unless metrics && owner == "timekeeping"
      missing
    end

    # Only Timekeeping keeps an outbox; the monolith has none to measure.
    def outbox_lag_by_owner(metrics)
      { "timekeeping" => metrics.fetch("outbox_lag") } if metrics
    end

    def pending_intents
      InvoiceOperationIntent.where(state: "pending").group(:company_id).minimum(:created_at)
                            .map { |company_id, oldest_created_at| { company_id:, oldest_created_at: } }
    end

    # Grouped by handoff step; the evaluator counts only those outside a handoff.
    def stale_generation_refusals(now)
      TimekeepingStaleGenerationRefusal.where(created_at: (now - STALE_GENERATION_LOOKBACK)..now)
                                       .group(:company_id, :handoff_step).count
                                       .map { |(company_id, handoff_step), count| { company_id:, handoff_step:, count: } }
    end
  end
end

# frozen_string_literal: true

module Timekeeping
  # Gathers the signals Timekeeping::Alerts.evaluate reads, from the monolith's
  # own records, its event history and the Timekeeping service's metrics
  # endpoint.
  #
  # A signal with no source is listed in unavailable and left out of signals,
  # never set to zero, because a zero would read as healthy. Signals with no
  # producer in this repository yet are always unavailable. A local read that
  # fails makes only its own signal unavailable. A failed metrics read makes
  # the metrics-based signals unavailable too, and sets metrics_error, so the
  # caller can still report the monolith-side alerts and then fail.
  #
  # Every read is read-only: the event history stays as observability, and a
  # second run inside the lookback sees the same records.
  module AlertSignals
    # A record stays countable for two runs of a task started every 5 minutes.
    SIGNAL_LOOKBACK = 10.minutes

    # Named as the Timekeeping::Alerts rows they would feed.
    NO_SOURCE = %w[ownership_moving].freeze
    METRICS_SIGNALS = %w[reference_unavailable_rate entry_write_p95_latency].freeze
    OUTBOX_LAG = "outbox_lag"

    RECONCILIATION_EVENT = "Timekeeping::ReconciliationDifferenceFound"
    SNAPSHOT_EVENT = "Timekeeping::FinancialSnapshotChanged"
    PREPARE_REFUSAL_REASON = "on_another_invoice"

    # Alert row name => signals key, which is also the name of the reader that
    # fills it. Each reader takes the current time.
    LOCAL_SIGNALS = {
      "stale_generation" => :stale_generation_refusals,
      "prepare_refusal" => :prepare_refusals,
      "reconciliation_difference" => :reconciliation_differences,
      "financial_snapshot_change" => :financial_snapshot_changes
    }.freeze

    module_function

    # Returns { signals:, unavailable: [signal names], metrics_error: String or nil }.
    def gather(metrics_client:, now:)
      metrics, metrics_error = read_metrics(metrics_client)
      owner = TimekeepingOwnership.current.owner
      local, failed = read_local_signals(now)
      signals = {
        now:,
        owner:,
        pending_intents: pending_intents,
        **local,
        write_metrics: metrics,
        outbox_lag_by_owner: outbox_lag_by_owner(metrics)
      }.compact

      { signals:, unavailable: unavailable(metrics, owner) + failed, metrics_error: }
    end

    def read_metrics(metrics_client)
      [metrics_client.fetch, nil]
    rescue MetricsClient::Error => error
      [nil, error.message]
    end

    # Returns [{ signals key => value }, [names of signals whose read failed]].
    def read_local_signals(now)
      LOCAL_SIGNALS.each_with_object([{}, []]) do |(name, key), (read, failed)|
        read[key] = public_send(key, now)
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.warn("timekeeping alert signal #{name} not read: #{error.class}")
        failed << name
      end
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
      TimekeepingStaleGenerationRefusal.where(created_at: lookback(now))
                                       .group(:company_id, :handoff_step).count
                                       .map { |(company_id, handoff_step), count| { company_id:, handoff_step:, count: } }
    end

    # Section 11.3 names prepare refusals for on_another_invoice only; other
    # conflict reasons are recorded but raise no alert.
    def prepare_refusals(now)
      TimekeepingPrepareRefusal.where(reason: PREPARE_REFUSAL_REASON, created_at: lookback(now))
                               .group(:company_id).count
                               .map { |company_id, count| { company_id:, count: } }
    end

    # Section 11.3 alerts on "any unexplained difference": a difference the
    # pre-flight listed is explained. A row without the listed flag counts,
    # so a malformed row is never dropped.
    def reconciliation_differences(now)
      event_counts_by_company(
        RailsEventViewer::Entry.where(name: RECONCILIATION_EVENT, occurred_at: lookback(now))
                               .where("(payload -> 'data' ->> 'listed') IS DISTINCT FROM 'true'")
      )
    end

    def financial_snapshot_changes(now)
      event_counts_by_company(RailsEventViewer::Entry.where(name: SNAPSHOT_EVENT, occurred_at: lookback(now)))
    end

    # Event history is free-form JSON, so a company_id that is missing or not
    # an integer is counted under no company, which the alert prints as
    # company_id=all, rather than dropped.
    def event_counts_by_company(events)
      events.group(Arel.sql("payload -> 'data' ->> 'company_id'")).count
            .each_with_object(Hash.new(0)) { |(company_id, count), counts| counts[Integer(company_id, exception: false)] += count }
            .map { |company_id, count| { company_id:, count: } }
    end

    def lookback(now)
      (now - SIGNAL_LOOKBACK)..now
    end
  end
end

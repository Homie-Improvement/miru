# frozen_string_literal: true

module Timekeeping
  # Gathers the inputs of Timekeeping::Alerts from the monolith's own tables
  # and from the Timekeeping metrics endpoint. Every per-company value is
  # grouped by company_id, so no company's counts are mixed with another's.
  #
  # Some section 11.3 signals have no producer in the repository yet: nothing
  # sets a handoff step or answers 503 ownership_moving, nothing refuses a
  # prepare with on_another_invoice, no reconciliation runs, and Timekeeping's
  # outbox has no sent marker. Those signals are nil, which the evaluator lists
  # as unsourced instead of reading them as quiet.
  module AlertSignals
    MONOLITH_OWNER = "monolith"

    OLDEST_UNSENT_OUTBOX_SQL = <<~SQL.squish
      SELECT company_id, MIN(created_at) AS oldest
      FROM entry_outbox_items
      WHERE sent_at IS NULL
      GROUP BY company_id
    SQL

    module_function

    # metrics_client answers fetch with the validated metrics body, or raises.
    def gather(now:, metrics_client:)
      ownership = TimekeepingOwnership.current
      metrics = metrics_client.fetch

      Alerts::Signals.new(
        now:,
        outbox_lag_seconds_by_company: outbox_lag(ownership, now),
        pending_intent_age_seconds_by_company: pending_intent_ages(now),
        write_pause_seconds: nil,
        stale_generation_outside_handoff_by_company: stale_generation_outside_handoff(ownership, metrics, now),
        write_metrics: metrics,
        prepare_refusals_by_company: nil,
        unexplained_reconciliation_differences_by_company: nil,
        financial_snapshot_changes_by_company: nil
      )
    end

    # Only the monolith's outbox records sends, so the lag is known only while
    # the monolith owns the entries.
    def outbox_lag(ownership, now)
      return unless ownership.owner == MONOLITH_OWNER

      rows = ActiveRecord::Base.connection.select_all(OLDEST_UNSENT_OUTBOX_SQL).cast_values
      ages_since(rows, now)
    end

    def pending_intent_ages(now)
      ages_since(InvoiceOperationIntent.where(state: "pending").group(:company_id).minimum(:created_at), now)
    end

    # A stale generation during a handoff is expected, so the counts apply only
    # while no handoff step is set.
    def stale_generation_outside_handoff(ownership, metrics, now)
      return {} if ownership.handoff_step

      recent_since = now - Alerts::RECENT_WINDOW_SECONDS
      metrics.fetch("companies").to_h do |company|
        recent = company.fetch("windows").select { |window| Time.iso8601(window.fetch("window_start")) > recent_since }
        [company.fetch("company_id"), recent.sum { |window| window.fetch("stale_generation") }]
      end
    end

    def ages_since(oldest_by_company, now)
      oldest_by_company.to_h { |company_id, oldest| [company_id, now - oldest] }
    end
  end
end

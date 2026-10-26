# frozen_string_literal: true

module Timekeeping
  # The GET /internal/v1/metrics body: every stored window, grouped under its
  # own company, and each company's outbox lag. It carries counts and ages
  # only, never a token, user or entry, and no total summed across companies. The window length and
  # bucket bounds come from Timekeeping::WriteMetrics, so the alert evaluator
  # reads them here instead of keeping its own copy.
  module WriteMetricsPresenter
    # What the reference_unavailable rate divides by: the two counts never
    # overlap (Timekeeping::WriteMetrics).
    TOTAL_FIELD = "writes + reference_unavailable"

    module_function

    # windows must be ordered by company_id, then window_start. oldest_unsent
    # maps company_id to the enqueued_at of that company's oldest unsent outbox
    # row (OutboxSnapshot.oldest_unsent_by_company); outbox_lag reports its age
    # at now, in whole seconds.
    def call(windows, oldest_unsent:, now:)
      {
        "window_seconds" => WriteMetrics::WINDOW_SECONDS,
        "latency_bucket_bounds_ms" => WriteMetrics::LATENCY_BUCKET_BOUNDS_MS,
        "overflow_bucket" => WriteMetrics::OVERFLOW_BUCKET,
        "total_field" => TOTAL_FIELD,
        "companies" => windows.group_by(&:company_id).map do |company_id, company_windows|
          { "company_id" => company_id, "windows" => company_windows.map { |window| window_fields(window) } }
        end,
        "outbox_lag" => oldest_unsent.sort.map do |company_id, enqueued_at|
          { "company_id" => company_id, "oldest_unsent_age_seconds" => (now - enqueued_at).floor }
        end
      }
    end

    def window_fields(window)
      {
        "window_start" => window.window_start.utc.iso8601,
        "writes" => window.writes,
        "reference_unavailable" => window.reference_unavailable,
        "latency_ms_sum" => window.latency_ms_sum,
        "latency_ms_buckets" => window.latency_ms_buckets
      }
    end
  end
end

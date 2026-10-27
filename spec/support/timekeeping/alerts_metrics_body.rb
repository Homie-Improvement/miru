# frozen_string_literal: true

# The Timekeeping /internal/v1/metrics body the alert specs send when a case
# does not care about the metrics. It holds every field the metrics read
# expects, so a spec that needs other values overrides single fields instead
# of dropping any.
module TimekeepingAlertsMetricsBody
  TIMEKEEPING_ALERTS_METRICS_BODY = {
    "window_seconds" => 300,
    "latency_bucket_bounds_ms" => [25, 50, 100, 200, 300, 500, 1000, 2500, 5000],
    "overflow_bucket" => "inf",
    "total_field" => "writes + reference_unavailable",
    "companies" => [],
    "outbox_lag" => []
  }.freeze

  # Returns a deep copy, so a spec that appends to a nested list changes only
  # its own body and never the default later examples read.
  def timekeeping_alerts_metrics_body(**fields)
    TIMEKEEPING_ALERTS_METRICS_BODY.deep_dup.merge(fields.transform_keys(&:to_s))
  end
end

RSpec.configure do |config|
  config.include TimekeepingAlertsMetricsBody
end

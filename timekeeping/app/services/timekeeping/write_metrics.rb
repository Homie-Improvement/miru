# frozen_string_literal: true

module Timekeeping
  # Counts entry writes per company in five-minute windows, in the
  # write_metric_windows table, so every process adds to the same numbers.
  #
  # writes and reference_unavailable count different requests: a write refused
  # with 503 reference_unavailable adds to reference_unavailable only. Every
  # recorded request adds its latency to latency_ms_sum and to exactly one
  # bucket, so the bucket counts sum to writes + reference_unavailable and the
  # alert evaluator can read the p95 latency from them.
  class WriteMetrics
    WINDOW_SECONDS = 300
    # Upper bounds in ms. 300 is an exact edge, so the p95 alert at 300 ms
    # never has to split a bucket.
    LATENCY_BUCKET_BOUNDS_MS = [25, 50, 100, 200, 300, 500, 1000, 2500, 5000].freeze
    OVERFLOW_BUCKET = "inf"
    # The [writes, reference_unavailable] increments for each outcome.
    OUTCOME_COUNTS = { write: [1, 0].freeze, reference_unavailable: [0, 1].freeze }.freeze

    # The start of the five-minute UTC window that holds time, in whole seconds.
    def self.window_start(time)
      seconds = time.to_i
      Time.at(seconds - (seconds % WINDOW_SECONDS)).utc
    end

    # A 503 is only ever reference_unavailable (Timekeeping::Reasons::STATUS);
    # every other answer counts as a write.
    def self.outcome_for(status)
      status == Reasons.status(:reference_unavailable) ? :reference_unavailable : :write
    end

    # The key of the one bucket a latency, in whole ms, falls into.
    def self.bucket_key(latency_ms)
      bound = LATENCY_BUCKET_BOUNDS_MS.find { |upper| latency_ms <= upper }
      bound ? bound.to_s : OVERFLOW_BUCKET
    end

    # clock answers call with the current Time.
    def initialize(clock:)
      @clock = clock
    end

    # One statement adds to the stored counts, so two processes recording into
    # the same window at once both count; the row is never read into Ruby.
    def record(company_id:, outcome:, latency_ms:)
      writes, reference_unavailable = OUTCOME_COUNTS.fetch(outcome) do
        raise ArgumentError, "unknown write metric outcome: #{outcome.inspect}"
      end
      latency = latency_ms.ceil
      bucket = self.class.bucket_key(latency)

      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish,
        INSERT INTO write_metric_windows
          (company_id, window_start, writes, reference_unavailable, latency_ms_sum, latency_ms_buckets)
        VALUES (?, ?, ?, ?, ?, jsonb_build_object(?::text, 1))
        ON CONFLICT (company_id, window_start) DO UPDATE SET
          writes = write_metric_windows.writes + EXCLUDED.writes,
          reference_unavailable = write_metric_windows.reference_unavailable + EXCLUDED.reference_unavailable,
          latency_ms_sum = write_metric_windows.latency_ms_sum + EXCLUDED.latency_ms_sum,
          latency_ms_buckets = write_metric_windows.latency_ms_buckets
            || jsonb_build_object(?::text, COALESCE((write_metric_windows.latency_ms_buckets ->> ?::text)::bigint, 0) + 1)
      SQL
        company_id, self.class.window_start(@clock.call), writes, reference_unavailable, latency,
        bucket, bucket, bucket]))
    end
  end
end

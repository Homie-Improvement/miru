# frozen_string_literal: true

module Timekeeping
  # Counts entry writes per company in five-minute windows, in the
  # write_metric_windows table, so every process adds to the same numbers.
  #
  # Recording a write only inserts a new write_metric_events row. Every write
  # of one company in one window shares a single window row, and another
  # session can hold that row's lock; an entry response must never wait for
  # it. fold_pending adds the pending events into their windows later, when
  # the metrics are read.
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
    # How long a fold waits for a company's held window row before it leaves
    # that company's events pending for the next fold, so a metrics read is
    # never held up by one stuck lock.
    LOCK_TIMEOUT_MS = 100

    # Moves one company's pending events into its window rows in one
    # statement: the delete and the additions commit or roll back together, so
    # an event is counted exactly once. SKIP LOCKED leaves events another fold
    # is already moving to that fold. Bucket counts are added key by key.
    FOLD_COMPANY_SQL = <<~SQL.squish
      WITH moved AS (
        DELETE FROM write_metric_events
        WHERE id IN (SELECT id FROM write_metric_events WHERE company_id = ? FOR UPDATE SKIP LOCKED)
        RETURNING company_id, window_start, writes, reference_unavailable, latency_ms, latency_bucket
      ),
      bucket_counts AS (
        SELECT window_start, jsonb_object_agg(latency_bucket, events) AS buckets
        FROM (SELECT window_start, latency_bucket, COUNT(*) AS events FROM moved GROUP BY window_start, latency_bucket) per_bucket
        GROUP BY window_start
      ),
      totals AS (
        SELECT company_id, window_start, SUM(writes) AS writes, SUM(reference_unavailable) AS reference_unavailable,
          SUM(latency_ms) AS latency_ms_sum
        FROM moved GROUP BY company_id, window_start
      ),
      added AS (
        INSERT INTO write_metric_windows
          (company_id, window_start, writes, reference_unavailable, latency_ms_sum, latency_ms_buckets)
        SELECT totals.company_id, totals.window_start, totals.writes, totals.reference_unavailable,
          totals.latency_ms_sum, bucket_counts.buckets
        FROM totals JOIN bucket_counts USING (window_start)
        ON CONFLICT (company_id, window_start) DO UPDATE SET
          writes = write_metric_windows.writes + EXCLUDED.writes,
          reference_unavailable = write_metric_windows.reference_unavailable + EXCLUDED.reference_unavailable,
          latency_ms_sum = write_metric_windows.latency_ms_sum + EXCLUDED.latency_ms_sum,
          latency_ms_buckets = write_metric_windows.latency_ms_buckets || (
            SELECT jsonb_object_agg(added_bucket.key,
              COALESCE((write_metric_windows.latency_ms_buckets ->> added_bucket.key)::bigint, 0)
                + added_bucket.value::bigint)
            FROM jsonb_each_text(EXCLUDED.latency_ms_buckets) AS added_bucket
          )
        RETURNING 1
      )
      SELECT COUNT(*) FROM moved
    SQL

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

    # Adds every pending event into its window and returns how many it added.
    # Each company folds in its own transaction, so a company whose window row
    # is held only keeps its own events pending; the lock timeout rolls that
    # company's transaction back whole, and the next fold counts them.
    def self.fold_pending
      pending_company_ids = WriteMetricEvent.distinct.pluck(:company_id)
      pending_company_ids.sum { |company_id| fold_company(company_id) }
    end

    # The window rows in reading order, with every foldable pending event
    # already added.
    def self.folded_windows
      fold_pending
      WriteMetricWindow.order(:company_id, :window_start)
    end

    # requires_new makes this a savepoint inside an open transaction, so a
    # timeout rolls back only this company, and that rollback also undoes the
    # SET LOCAL. Releasing a savepoint does not undo a SET LOCAL: it would
    # last until the caller's transaction ends, so a successful fold puts the
    # caller's lock_timeout back before it returns.
    def self.fold_company(company_id)
      connection = ApplicationRecord.connection
      ApplicationRecord.transaction(requires_new: true) do
        caller_lock_timeout = connection.select_value("SELECT current_setting('lock_timeout')")
        connection.execute("SET LOCAL lock_timeout = #{Integer(LOCK_TIMEOUT_MS)}")
        folded = connection.select_value(ApplicationRecord.sanitize_sql_array([FOLD_COMPANY_SQL, company_id]))
        connection.select_value(
          ApplicationRecord.sanitize_sql_array(["SELECT set_config('lock_timeout', ?, true)", caller_lock_timeout])
        )
        folded
      end
    rescue ActiveRecord::LockWaitTimeout
      0
    end
    private_class_method :fold_company

    # Inserts the write as a new pending event; no other row is touched, so a
    # held window row cannot make it wait. The window is fixed now, so a later
    # fold still counts it in the window it happened in.
    def record(company_id:, outcome:, latency_ms:)
      writes, reference_unavailable = OUTCOME_COUNTS.fetch(outcome) do
        raise ArgumentError, "unknown write metric outcome: #{outcome.inspect}"
      end
      latency = latency_ms.ceil

      WriteMetricEvent.create!(company_id:, window_start: self.class.window_start(@clock.call), writes:,
                               reference_unavailable:, latency_ms: latency,
                               latency_bucket: self.class.bucket_key(latency))
    end
  end
end

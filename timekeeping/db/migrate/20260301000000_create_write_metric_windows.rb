# frozen_string_literal: true

class CreateWriteMetricWindows < ActiveRecord::Migration[8.1]
  def change
    # One row per company and five-minute window, shared by every process.
    # Timekeeping::WriteMetrics adds to a row with one INSERT ... ON CONFLICT
    # statement, so concurrent writers never lose a count. writes and
    # reference_unavailable count different requests; latency_ms_buckets maps
    # each bucket's upper bound in ms (or "inf") to its count, so the alert
    # evaluator can compute p95.
    create_table :write_metric_windows do |t|
      t.bigint :company_id, null: false
      t.datetime :window_start, null: false
      t.bigint :writes, null: false, default: 0
      t.bigint :reference_unavailable, null: false, default: 0
      t.bigint :latency_ms_sum, null: false, default: 0
      t.jsonb :latency_ms_buckets, null: false, default: {}

      t.index %i[company_id window_start], unique: true
    end
  end
end

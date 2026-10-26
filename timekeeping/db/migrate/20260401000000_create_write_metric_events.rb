# frozen_string_literal: true

class CreateWriteMetricEvents < ActiveRecord::Migration[8.1]
  def change
    # One row per recorded entry write, waiting to be added into
    # write_metric_windows. An entry request only inserts a new row here, which
    # never waits on the shared window row's lock, so a held window row cannot
    # delay the entry's response. window_start is fixed when the write is
    # recorded, so a late fold still counts it in the window it happened in.
    # latency_bucket is the key of the latency_ms_buckets entry it adds to.
    create_table :write_metric_events do |t|
      t.bigint :company_id, null: false
      t.datetime :window_start, null: false
      t.bigint :writes, null: false
      t.bigint :reference_unavailable, null: false
      t.bigint :latency_ms, null: false
      t.string :latency_bucket, null: false

      t.index :company_id
    end
  end
end

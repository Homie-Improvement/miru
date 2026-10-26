# frozen_string_literal: true

class AddStaleGenerationToWriteMetricWindows < ActiveRecord::Migration[8.1]
  def change
    # How many of the window's writes were refused with 409 stale_generation.
    # It is a subset of writes, so the reference_unavailable rate keeps its
    # denominator.
    add_column :write_metric_windows, :stale_generation, :bigint, null: false, default: 0
  end
end

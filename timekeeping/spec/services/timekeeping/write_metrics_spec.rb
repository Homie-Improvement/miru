# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics do
  let(:window_noon) { Time.utc(2026, 3, 3, 12) }
  let(:company_a) { 101 }
  let(:company_b) { 202 }

  def record_write_metric_at(time, company_id: company_a, outcome: :write, latency_ms: 10)
    described_class.new(clock: -> { time }).record(company_id:, outcome:, latency_ms:)
  end

  def write_metric_rows(company_id = company_a)
    WriteMetricWindow.where(company_id:).order(:window_start).to_a
  end

  # The upper bound of the bucket that holds the 95th percentile, read the way
  # the alert evaluator reads it: buckets in bound order, counted up until 95%
  # of the window's requests are covered.
  def p95_upper_bound(row)
    total = row.writes + row.reference_unavailable
    keys = described_class::LATENCY_BUCKET_BOUNDS_MS.map(&:to_s) + [described_class::OVERFLOW_BUCKET]
    covered = 0
    keys.each do |key|
      covered += row.latency_ms_buckets.fetch(key, 0)
      return key if covered >= total * 0.95
    end
  end

  describe "windows" do
    it "adds a record 4m59s after the window start to the same row" do
      record_write_metric_at(window_noon)
      record_write_metric_at(window_noon + 299)

      rows = write_metric_rows
      expect(rows.map { |row| [row.window_start, row.writes] }).to eq([[window_noon, 2]])
    end

    it "opens a new window for a record exactly 5 minutes after the window start" do
      record_write_metric_at(window_noon)
      record_write_metric_at(window_noon + 300)

      expect(write_metric_rows.map { |row| [row.window_start, row.writes] })
        .to eq([[window_noon, 1], [window_noon + 300, 1]])
    end

    it "floors the clock's time to the five-minute UTC boundary in whole seconds" do
      record_write_metric_at(Time.utc(2026, 3, 3, 12, 3, 17.5))

      expect(write_metric_rows.map(&:window_start)).to eq([window_noon])
      expect(described_class.window_start(Time.new(2026, 3, 3, 14, 7, 0, "+02:00"))).to eq(window_noon + 300)
    end
  end

  describe "counts" do
    it "adds a reference_unavailable record to reference_unavailable only" do
      record_write_metric_at(window_noon, outcome: :reference_unavailable)

      row = write_metric_rows.sole
      expect([row.writes, row.reference_unavailable]).to eq([0, 1])
    end

    it "keeps each company's counts in its own row" do
      record_write_metric_at(window_noon, company_id: company_a)
      record_write_metric_at(window_noon, company_id: company_a, outcome: :reference_unavailable)

      expect(write_metric_rows(company_b)).to be_empty
      expect(write_metric_rows(company_a).map { |row| [row.writes, row.reference_unavailable] }).to eq([[1, 1]])
    end

    it "raises ArgumentError for an unknown outcome and writes nothing" do
      expect { record_write_metric_at(window_noon, outcome: :refused) }.to raise_error(ArgumentError)
      expect(WriteMetricWindow.count).to eq(0)
    end
  end

  describe "latency" do
    it "puts each latency in the first bucket whose bound holds it and sums the latencies" do
      [300, 301, 6000].each { |latency_ms| record_write_metric_at(window_noon, latency_ms:) }

      row = write_metric_rows.sole
      expect(row.latency_ms_buckets).to eq("300" => 1, "500" => 1, "inf" => 1)
      expect(row.latency_ms_sum).to eq(6601)
    end

    it "rounds a fractional latency up, so 300.4 ms counts as over 300 ms" do
      record_write_metric_at(window_noon, latency_ms: 300.4)

      expect(write_metric_rows.sole.latency_ms_buckets).to eq("500" => 1)
    end

    it "puts p95 at or below 300 ms when 1 of 20 requests took 400 ms" do
      19.times { record_write_metric_at(window_noon, latency_ms: 100) }
      record_write_metric_at(window_noon, outcome: :reference_unavailable, latency_ms: 400)

      expect(p95_upper_bound(write_metric_rows.sole).to_i).to be <= 300
    end

    it "puts p95 above 300 ms when 2 of 20 requests took 400 ms" do
      18.times { record_write_metric_at(window_noon, latency_ms: 100) }
      2.times { record_write_metric_at(window_noon, latency_ms: 400) }

      expect(p95_upper_bound(write_metric_rows.sole)).to eq("500")
    end

    it "keeps the bucket counts equal to writes plus reference_unavailable" do
      [10, 250, 300, 999, 7000].each { |latency_ms| record_write_metric_at(window_noon, latency_ms:) }
      2.times { record_write_metric_at(window_noon, outcome: :reference_unavailable, latency_ms: 40) }

      row = write_metric_rows.sole
      expect(row.latency_ms_buckets.values.sum).to eq(row.writes + row.reference_unavailable)
    end
  end

  describe "OUTCOME_COUNTS" do
    it "freezes the table and each of its increment rows" do
      expect(described_class::OUTCOME_COUNTS).to be_frozen
      expect(described_class::OUTCOME_COUNTS.values).to all(be_frozen)
    end
  end

  describe ".outcome_for" do
    it "maps 503 to reference_unavailable and every other status to write" do
      expect([503, 201, 500, 401].map { |status| described_class.outcome_for(status) })
        .to eq(%i[reference_unavailable write write write])
    end
  end

  describe "from two connections at once" do
    include_context "timekeeping entry writes without transactional fixtures"

    it "adds both records to one row" do
      start = Queue.new
      threads = Array.new(2) do
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            start.pop
            record_write_metric_at(window_noon)
          end
        end
      end
      2.times { start << true }
      threads.each { |thread| thread.join(10) }

      expect(write_metric_rows.map(&:writes)).to eq([2])
    end
  end
end

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

# Generated by Descant: acceptance tests below.

RSpec.describe Timekeeping::WriteMetrics do
  # A stale_generation refusal still counts as a write, so the
  # reference_unavailable rate keeps its denominator; stale_generation is a
  # subset of writes.
  it "stores a stale_generation refusal in stale_generation and in writes for its own company only" do
    window = Time.utc(2026, 4, 1, 9)
    metrics = described_class.new(clock: -> { window + 5 })

    metrics.record(company_id: 301, outcome: :write, latency_ms: 20, reason: :stale_generation)
    metrics.record(company_id: 301, outcome: :write, latency_ms: 20, reason: :stale_generation)
    metrics.record(company_id: 302, outcome: :write, latency_ms: 20, reason: nil)

    stored = WriteMetricWindow.order(:company_id).map do |row|
      [row.company_id, row.writes, row.reference_unavailable, row.stale_generation]
    end
    expect(stored).to eq([[301, 2, 0, 2], [302, 1, 0, 0]])
  end
end

RSpec.describe Timekeeping::WriteMetrics do
  # version_conflict shares status 409 with stale_generation, so only the
  # reason may decide the stale_generation count.
  it "leaves stale_generation at zero for version_conflict and reference_unavailable answers" do
    window = Time.utc(2026, 4, 1, 10)
    metrics = described_class.new(clock: -> { window + 5 })

    metrics.record(company_id: 303, outcome: :write, latency_ms: 20, reason: :version_conflict)
    metrics.record(company_id: 303, outcome: :reference_unavailable, latency_ms: 20, reason: :reference_unavailable)

    row = WriteMetricWindow.find_by!(company_id: 303)
    expect([row.writes, row.reference_unavailable, row.stale_generation]).to eq([1, 1, 0])
  end
end

RSpec.describe Timekeeping::WriteMetrics do
  it "counts a stale_generation answer only in the row of the company that received it" do
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon })

    metrics.record(company_id: 701, outcome: :write, latency_ms: 10, reason: :stale_generation)
    metrics.record(company_id: 702, outcome: :write, latency_ms: 10, reason: nil)

    rows = WriteMetricWindow.order(:company_id).to_a
    expect(rows.map { |row| [row.company_id, row.writes, row.stale_generation] })
      .to eq([[701, 1, 1], [702, 1, 0]])
  end
end

RSpec.describe Timekeeping::WriteMetrics do
  # "any `409 stale_generation` outside a handoff;"
  # 409 is shared with version_conflict, so only the stale_generation reason is counted.
  it "counts a stale_generation refusal in stale_generation and writes but not a version_conflict" do
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon })

    metrics.record(company_id: 101, outcome: :write, latency_ms: 10, reason: :stale_generation)
    metrics.record(company_id: 101, outcome: :write, latency_ms: 10, reason: :version_conflict)
    metrics.record(company_id: 202, outcome: :write, latency_ms: 10, reason: nil)

    row = WriteMetricWindow.find_by!(company_id: 101)
    expect([row.writes, row.stale_generation]).to eq([2, 1])
    expect(WriteMetricWindow.find_by!(company_id: 202).stale_generation).to eq(0)
  end
end

RSpec.describe Timekeeping::WriteMetrics do
  # "any `409 stale_generation` outside a handoff;" -- version_conflict shares status 409,
  # so counting by status alone would raise a false stale_generation alert.
  it "counts a 409 version_conflict as a write but never as stale_generation" do
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon })

    metrics.record(company_id: 303, outcome: :write, latency_ms: 10, reason: :version_conflict)
    metrics.record(company_id: 404, outcome: :write, latency_ms: 10, reason: :stale_generation)

    conflict_row = WriteMetricWindow.find_by!(company_id: 303)
    stale_row = WriteMetricWindow.find_by!(company_id: 404)
    expect([conflict_row.writes, conflict_row.stale_generation]).to eq([1, 0])
    expect([stale_row.writes, stale_row.stale_generation]).to eq([1, 1])
  end
end

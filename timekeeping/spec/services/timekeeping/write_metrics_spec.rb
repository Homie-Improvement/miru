# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics do
  let(:window_noon) { Time.utc(2026, 3, 3, 12) }
  let(:company_a) { 101 }
  let(:company_b) { 202 }

  def record_write_metric_at(time, company_id: company_a, outcome: :write, latency_ms: 10)
    described_class.new(clock: -> { time }).record(company_id:, outcome:, latency_ms:)
  end

  # Folds pending events first, since record only appends them.
  def write_metric_rows(company_id = company_a)
    described_class.fold_pending
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
      expect(WriteMetricEvent.count).to eq(0)
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
RSpec.describe Timekeeping::WriteMetrics, "folding pending events" do
  it "folds each pending event into its window exactly once, so a second fold adds nothing" do
    noon = Time.utc(2026, 3, 3, 12)
    described_class.new(clock: -> { noon + 10 }).record(company_id: 101, outcome: :write, latency_ms: 40)
    described_class.new(clock: -> { noon + 20 }).record(company_id: 101, outcome: :reference_unavailable,
                                                        latency_ms: 400)

    expect(described_class.fold_pending).to eq(2)
    row = WriteMetricWindow.find_by!(company_id: 101)
    folded_once = [row.window_start, row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets]
    expect(folded_once).to eq([noon, 1, 1, 440, { "50" => 1, "500" => 1 }])

    # A repeated fold must not re-send an event that was already counted.
    expect(described_class.fold_pending).to eq(0)
    row.reload
    expect([row.window_start, row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets])
      .to eq(folded_once)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "folding late" do
  include ActiveSupport::Testing::TimeHelpers

  it "keeps a pending event in the window of its record time when it is folded after that window ends" do
    noon = Time.utc(2026, 3, 3, 12)
    described_class.new(clock: -> { noon + 299 }).record(company_id: 101, outcome: :write, latency_ms: 10)

    travel_to(noon + 600) { described_class.fold_pending }

    expect(WriteMetricWindow.where(company_id: 101).pluck(:window_start, :writes)).to eq([[noon, 1]])
  end
end

RSpec.describe Timekeeping::WriteMetrics, "folding against a held window row" do
  include_context "timekeeping entry writes without transactional fixtures"

  after { ApplicationRecord.connection.execute("TRUNCATE write_metric_events") }

  # The issue asks for persistence that "preserves counts rather than discarding timed-out events".
  it "keeps an event whose fold timed out on a held window row and counts it once after the lock is released" do
    stub_const("Timekeeping::WriteMetrics::LOCK_TIMEOUT_MS", 200)
    noon = Time.utc(2026, 3, 3, 12)
    recorder = described_class.new(clock: -> { noon + 30 })
    recorder.record(company_id: 101, outcome: :write, latency_ms: 40)
    described_class.fold_pending
    recorder.record(company_id: 101, outcome: :write, latency_ms: 40)

    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute(
            "SELECT 1 FROM write_metric_windows WHERE company_id = 101 FOR UPDATE"
          )
          locked << true
          release.pop
        end
      end
    end

    begin
      expect(locked.pop(timeout: 10)).to be(true)
      expect(described_class.fold_pending).to eq(0)
    ensure
      release << true
      holder.join(10)
    end

    expect(WriteMetricWindow.find_by!(company_id: 101).writes).to eq(1)
    expect(described_class.fold_pending).to eq(1)
    expect(described_class.fold_pending).to eq(0)
    row = WriteMetricWindow.find_by!(company_id: 101)
    expect([row.writes, row.latency_ms_sum, row.latency_ms_buckets]).to eq([2, 80, { "50" => 2 }])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics, "recording while the window row is held" do
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue asks for work that "preserves counts rather than discarding timed-out events":
  # a record made while another session holds the counter row must return at once and still be counted.
  it "returns from record while the company's window row is held and keeps that event until a fold after release" do
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon + 30 })
    metrics.record(company_id: 303, outcome: :write, latency_ms: 10)
    described_class.fold_pending

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT 1 FROM write_metric_windows WHERE company_id = 303 FOR UPDATE")
          held << true
          release.pop
        end
      end
    end
    begin
      expect(held.pop(timeout: 10)).to be(true)
      recorder = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          metrics.record(company_id: 303, outcome: :reference_unavailable, latency_ms: 20)
        end
      end
      expect(recorder.join(3)).not_to be_nil, "record waited on the held window row"
    ensure
      release << true
      holder.join(10)
    end

    expect(described_class.fold_pending).to eq(1)
    row = WriteMetricWindow.find_by!(company_id: 303)
    expect([row.writes, row.reference_unavailable, row.latency_ms_sum]).to eq([1, 1, 30])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics, "folded windows around a held row" do
  include_context "timekeeping entry writes without transactional fixtures"

  # The issue asks for work that "preserves counts rather than discarding timed-out events":
  # a fold that times out on a held row keeps the event, and the next read counts it exactly once.
  it "answers folded_windows while one company's row is held and includes that company's kept event once the lock clears" do
    stub_const("Timekeeping::WriteMetrics::LOCK_TIMEOUT_MS", 200)
    metrics = described_class.new(clock: -> { Time.utc(2026, 3, 3, 12, 1) })
    metrics.record(company_id: 404, outcome: :write, latency_ms: 10)
    described_class.folded_windows.to_a

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT 1 FROM write_metric_windows WHERE company_id = 404 FOR UPDATE")
          held << true
          release.pop
        end
      end
    end
    begin
      expect(held.pop(timeout: 10)).to be(true)
      metrics.record(company_id: 404, outcome: :write, latency_ms: 10)
      metrics.record(company_id: 505, outcome: :write, latency_ms: 10)

      during = described_class.folded_windows.to_a.to_h { |row| [row.company_id, row.writes] }
      expect(during).to eq(404 => 1, 505 => 1)
    ensure
      release << true
      holder.join(10)
    end

    after = described_class.folded_windows.to_a.to_h { |row| [row.company_id, row.writes] }
    expect(after).to eq(404 => 2, 505 => 1)
    expect(described_class.folded_windows.to_a.to_h { |row| [row.company_id, row.writes] }).to eq(after)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics, "folding pending events per company" do
  it "folds each company's pending events only into that company's own window rows" do
    noon = Time.utc(2026, 3, 3, 12)
    described_class.new(clock: -> { noon + 10 }).record(company_id: 101, outcome: :write, latency_ms: 20)
    described_class.new(clock: -> { noon + 20 }).record(company_id: 101, outcome: :reference_unavailable, latency_ms: 40)
    described_class.new(clock: -> { noon + 30 }).record(company_id: 202, outcome: :write, latency_ms: 600)

    expect(described_class.fold_pending).to eq(3)

    rows = WriteMetricWindow.order(:company_id).map do |row|
      [row.company_id, row.window_start, row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets]
    end
    expect(rows).to eq([
      [101, noon, 1, 1, 60, { "25" => 1, "50" => 1 }],
      [202, noon, 1, 0, 600, { "1000" => 1 }]
    ])
    expect(WriteMetricEvent.count).to eq(0)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics, "folding while another company's row is held" do
  include_context "timekeeping entry writes without transactional fixtures"

  it "folds another company's events while one company's window row is held and keeps the held company's events pending" do
    noon = Time.utc(2026, 3, 3, 12)
    recorder = described_class.new(clock: -> { noon + 10 })
    recorder.record(company_id: 101, outcome: :write, latency_ms: 20)
    described_class.fold_pending
    recorder.record(company_id: 101, outcome: :write, latency_ms: 20)
    recorder.record(company_id: 202, outcome: :write, latency_ms: 20)

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT 1 FROM write_metric_windows WHERE company_id = 101 FOR UPDATE")
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    begin
      folded = described_class.fold_pending
    ensure
      release << true
      holder.join(10)
    end

    # Company 101's held row must neither block nor absorb company 202's count.
    expect(folded).to eq(1)
    expect(WriteMetricWindow.where(company_id: 202).pluck(:writes)).to eq([1])
    expect(WriteMetricWindow.where(company_id: 101).pluck(:writes)).to eq([1])
    expect(WriteMetricEvent.where(company_id: 101).count).to eq(1)
    expect(WriteMetricEvent.where(company_id: 202).count).to eq(0)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "recording while the window row is locked" do
  include_context "timekeeping entry writes without transactional fixtures"

  it "returns while the company's window row is held on another connection and keeps the event pending" do
    window = Time.utc(2026, 3, 3, 12)
    company_id = 303
    WriteMetricWindow.create!(company_id:, window_start: window, writes: 1, reference_unavailable: 0,
                              latency_ms_sum: 10, latency_ms_buckets: { "25" => 1 })
    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.select_all(ApplicationRecord.sanitize_sql_array(
            ["SELECT id FROM write_metric_windows WHERE company_id = ? FOR UPDATE", company_id]
          ))
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    # The issue asks: "Does a locked metric row delay an entry response after the entry transaction commits?"
    recorder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        described_class.new(clock: -> { window + 30 }).record(company_id:, outcome: :write, latency_ms: 40)
      end
    end
    finished_while_held = recorder.join(3)
    release << true
    holder.join(10)
    recorder.join(10)

    expect(finished_while_held).not_to be_nil, "record waited on the held window row"
    expect(WriteMetricEvent.where(company_id:).count).to eq(1)
    expect(WriteMetricWindow.find_by!(company_id:).writes).to eq(1)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "folding past a locked window row" do
  include_context "timekeeping entry writes without transactional fixtures"

  it "keeps a held company's events through a fold timeout, folds other companies, and counts the kept event exactly once after release" do
    window = Time.utc(2026, 3, 3, 12)
    held_company = 404
    free_company = 505
    WriteMetricWindow.create!(company_id: held_company, window_start: window, writes: 1, reference_unavailable: 0,
                              latency_ms_sum: 10, latency_ms_buckets: { "25" => 1 })
    recorder = described_class.new(clock: -> { window + 30 })
    recorder.record(company_id: held_company, outcome: :write, latency_ms: 40)
    recorder.record(company_id: free_company, outcome: :reference_unavailable, latency_ms: 40)

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.select_all(ApplicationRecord.sanitize_sql_array(
            ["SELECT id FROM write_metric_windows WHERE company_id = ? FOR UPDATE", held_company]
          ))
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    folder = Thread.new { ApplicationRecord.connection_pool.with_connection { described_class.fold_pending } }
    folded_while_held = folder.join(5)&.value
    release << true
    holder.join(10)

    # "preserves counts rather than discarding timed-out events"
    expect(folded_while_held).to eq(1)
    expect(WriteMetricEvent.where(company_id: held_company).count).to eq(1)
    free_row = WriteMetricWindow.find_by!(company_id: free_company)
    expect([free_row.writes, free_row.reference_unavailable]).to eq([0, 1])

    expect(described_class.fold_pending).to eq(1)
    held_row = WriteMetricWindow.find_by!(company_id: held_company)
    expect([held_row.writes, held_row.latency_ms_sum, held_row.latency_ms_buckets]).to eq([2, 50, { "25" => 1, "50" => 1 }])
    expect(WriteMetricEvent.count).to eq(0)

    expect(described_class.fold_pending).to eq(0)
    expect(WriteMetricWindow.find_by!(company_id: held_company).writes).to eq(2)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "lock timeout scope" do
  include_context "timekeeping entry writes without transactional fixtures"

  it "leaves the connection's lock_timeout at the server default after a fold" do
    expect(described_class::LOCK_TIMEOUT_MS).to be_a(Integer)
    default_timeout = ApplicationRecord.connection.select_value("SHOW lock_timeout")
    described_class.new(clock: -> { Time.utc(2026, 3, 3, 12) }).record(company_id: 606, outcome: :write, latency_ms: 10)

    described_class.fold_pending

    expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq(default_timeout)
    expect(WriteMetricWindow.find_by!(company_id: 606).writes).to eq(1)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "late folds" do
  it "counts an event recorded at 12:04:59 in the 12:00 window when it is folded after 12:05" do
    window = Time.utc(2026, 3, 3, 12)
    described_class.new(clock: -> { window + 299 }).record(company_id: 707, outcome: :write, latency_ms: 10)
    described_class.new(clock: -> { window + 301 }).record(company_id: 808, outcome: :write, latency_ms: 10)

    expect(described_class.fold_pending).to eq(2)

    expect(WriteMetricWindow.where(company_id: 707).pluck(:window_start, :writes)).to eq([[window, 1]])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::WriteMetrics do
  # The fold waits at most this long for a held window row before it keeps
  # the company's events pending for the next metrics read.
  it "bounds the metric fold's lock wait at 100 ms" do
    expect(described_class::LOCK_TIMEOUT_MS).to eq(100)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "folding the same events twice" do
  # A metrics read can run fold_pending again over events an earlier read
  # already folded; the second run must add nothing.
  it "counts a pending event once when fold_pending runs twice" do
    noon = Time.utc(2026, 3, 3, 12)
    described_class.new(clock: -> { noon }).record(company_id: 101, outcome: :write, latency_ms: 40)

    first = described_class.fold_pending
    second = described_class.fold_pending

    expect([first, second]).to eq([1, 0])
    row = WriteMetricWindow.find_by!(company_id: 101)
    expect([row.writes, row.latency_ms_sum, row.latency_ms_buckets]).to eq([1, 40, { "50" => 1 }])
    expect(WriteMetricEvent.count).to eq(0)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "folding after the window has closed" do
  include ActiveSupport::Testing::TimeHelpers

  # The window is taken when the write is recorded, so a fold that runs in a
  # later window must not move the count there.
  it "folds an event recorded at 12:04:59 into the 12:00 window even when folded later" do
    noon = Time.utc(2026, 3, 3, 12)
    described_class.new(clock: -> { noon + 299 }).record(company_id: 101, outcome: :write, latency_ms: 10)

    travel_to(noon + 420) { described_class.fold_pending }

    rows = WriteMetricWindow.where(company_id: 101).order(:window_start)
    expect(rows.map { |row| [row.window_start, row.writes] }).to eq([[noon, 1]])
  end
end

RSpec.describe Timekeeping::WriteMetrics, "recording while the window row is locked" do
  include_context "timekeeping entry writes without transactional fixtures"

  # Does a locked metric row delay an entry response after the entry
  # transaction commits? record runs on the entry response path, so it must
  # not wait for the holder to release the counter row.
  it "returns from record while another session holds the company's window row" do
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon })
    metrics.record(company_id: 101, outcome: :write, latency_ms: 10)
    described_class.fold_pending

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SELECT 1 FROM write_metric_windows WHERE company_id = 101 FOR UPDATE")
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    recorder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        metrics.record(company_id: 101, outcome: :write, latency_ms: 10)
        :recorded
      end
    end
    finished = recorder.join(3)
    release << true
    holder.join(10)
    recorder.join(10)

    expect(finished&.value).to eq(:recorded), "record waited on the held window row"
    expect(WriteMetricEvent.where(company_id: 101).count).to eq(1)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "folding while one company's row is locked" do
  include_context "timekeeping entry writes without transactional fixtures"

  # treat response delivery independently from metric persistence as
  # follow-up work that preserves counts rather than discarding timed-out events.
  it "keeps a fold that timed out on a held row pending, folds other companies, and counts it once after release" do
    stub_const("Timekeeping::WriteMetrics::LOCK_TIMEOUT_MS", 1000)
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon })
    metrics.record(company_id: 101, outcome: :write, latency_ms: 10)
    described_class.fold_pending

    held = Queue.new
    release = Queue.new
    holder_pid = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        holder_pid << connection.select_value("SELECT pg_backend_pid()")
        ApplicationRecord.transaction do
          connection.execute("SELECT 1 FROM write_metric_windows WHERE company_id = 101 FOR UPDATE")
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)
    metrics.record(company_id: 101, outcome: :write, latency_ms: 10)
    metrics.record(company_id: 202, outcome: :write, latency_ms: 10)

    folder_pid = Queue.new
    folder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        folder_pid << connection.select_value("SELECT pg_backend_pid()")
        described_class.fold_pending
      end
    end
    waiting = folder_pid.pop(timeout: 10)
    holding = holder_pid.pop(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    blocked = false
    until blocked || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      blocked = ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql_array(["SELECT ? = ANY(pg_blocking_pids(?))", holding, waiting])
      )
      sleep 0.02 unless blocked
    end
    folded_while_held = folder.join(10)&.value
    pending_while_held = WriteMetricEvent.where(company_id: 101).count
    release << true
    holder.join(10)

    expect(blocked).to be(true), "the fold never waited on the held row"
    expect(folded_while_held).to eq(1)
    expect(pending_while_held).to eq(1)
    expect(WriteMetricWindow.find_by!(company_id: 202).writes).to eq(1)

    described_class.fold_pending
    expect(WriteMetricWindow.find_by!(company_id: 101).writes).to eq(2)
    expect(WriteMetricEvent.count).to eq(0)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "two folds at once" do
  include_context "timekeeping entry writes without transactional fixtures"

  # Two metrics reads can fold at the same moment; between them each pending
  # event must be added exactly once.
  it "counts every event once when two connections fold at the same time" do
    noon = Time.utc(2026, 3, 3, 12)
    metrics = described_class.new(clock: -> { noon })
    5.times { metrics.record(company_id: 101, outcome: :write, latency_ms: 10) }

    start = Queue.new
    folders = Array.new(2) do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          start.pop
          described_class.fold_pending
        end
      end
    end
    2.times { start << true }
    folded = folders.map { |thread| thread.join(10)&.value }

    expect(folded.sum).to eq(5)
    expect(WriteMetricWindow.where(company_id: 101).sum(:writes)).to eq(5)
    expect(WriteMetricEvent.count).to eq(0)
  end
end

RSpec.describe Timekeeping::WriteMetrics, "lock timeout scope" do
  include_context "timekeeping entry writes without transactional fixtures"

  # The pooled connection goes on to serve entry writes; a metric-sized lock
  # timeout left on it would cancel those writes.
  it "leaves the connection's lock_timeout as it was after record and fold_pending" do
    expect(described_class::LOCK_TIMEOUT_MS).to be_a(Integer)
    before = ApplicationRecord.connection.select_value("SHOW lock_timeout")

    described_class.new(clock: -> { Time.utc(2026, 3, 3, 12) }).record(company_id: 101, outcome: :write, latency_ms: 10)
    described_class.fold_pending

    expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq(before)
  end
end

RSpec.describe Timekeeping::WriteMetrics, ".folded_windows under a held window row" do
  include_context "timekeeping entry writes without transactional fixtures"

  let(:held_case_window) { Time.utc(2026, 3, 3, 12) }
  let(:held_case_company) { 303 }

  def held_case_record
    described_class.new(clock: -> { held_case_window + 5 })
                   .record(company_id: held_case_company, outcome: :write, latency_ms: 20)
  end

  def held_case_writes(relation)
    relation.select { |row| row.company_id == held_case_company }.sum(&:writes)
  end

  # This follows the settled plan, so treat response delivery independently from metric
  # persistence as follow-up work that preserves counts rather than discarding timed-out events.
  it "returns from folded_windows while a window row is held and shows the kept event once after release" do
    held_case_record
    expect(held_case_writes(described_class.folded_windows.to_a)).to eq(1)
    row_id = WriteMetricWindow.find_by!(company_id: held_case_company).id

    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT id FROM write_metric_windows WHERE id = #{row_id} FOR UPDATE")
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    expect(held.pop(timeout: 10)).to be(true)

    held_case_record
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    writes_while_held = held_case_writes(described_class.folded_windows.to_a)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    pending_while_held = WriteMetricEvent.where(company_id: held_case_company).count
    release << true
    holder.join(10)

    expect(elapsed).to be < 5
    expect(writes_while_held).to eq(1)
    expect(pending_while_held).to eq(1)
    expect(held_case_writes(described_class.folded_windows.to_a)).to eq(2)
    expect(held_case_writes(described_class.folded_windows.to_a)).to eq(2)
    expect(WriteMetricEvent.where(company_id: held_case_company).count).to eq(0)
  end
end

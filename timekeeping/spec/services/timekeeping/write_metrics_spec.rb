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

  # Generated by Descant: acceptance tests below.
  describe "pending events" do
    include ActiveSupport::Testing::TimeHelpers

    def pending_window_row(company_id)
      row = WriteMetricWindow.find_by!(company_id:)
      [row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets]
    end

    it "bounds the metric fold's lock wait at 100 ms" do
      expect(described_class::LOCK_TIMEOUT_MS).to eq(100)
    end

    it "folds each pending event into its window exactly once, so a second fold adds nothing" do
      record_write_metric_at(window_noon + 10, latency_ms: 40)
      record_write_metric_at(window_noon + 20, outcome: :reference_unavailable, latency_ms: 400)

      expect(described_class.fold_pending).to eq(2)
      row = WriteMetricWindow.find_by!(company_id: company_a)
      folded_once = [row.window_start, row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets]
      expect(folded_once).to eq([window_noon, 1, 1, 440, { "50" => 1, "500" => 1 }])
      expect(WriteMetricEvent.count).to eq(0)

      # A repeated fold must not re-send an event that was already counted.
      expect(described_class.fold_pending).to eq(0)
      row.reload
      expect([row.window_start, row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets])
        .to eq(folded_once)
    end

    it "folds each company's pending events only into that company's own window rows" do
      record_write_metric_at(window_noon + 10, company_id: 101, latency_ms: 20)
      record_write_metric_at(window_noon + 20, company_id: 101, outcome: :reference_unavailable, latency_ms: 40)
      record_write_metric_at(window_noon + 30, company_id: 202, latency_ms: 600)

      expect(described_class.fold_pending).to eq(3)

      rows = WriteMetricWindow.order(:company_id).map do |row|
        [row.company_id, row.window_start, row.writes, row.reference_unavailable, row.latency_ms_sum, row.latency_ms_buckets]
      end
      expect(rows).to eq([
        [101, window_noon, 1, 1, 60, { "25" => 1, "50" => 1 }],
        [202, window_noon, 1, 0, 600, { "1000" => 1 }]
      ])
      expect(WriteMetricEvent.count).to eq(0)
    end

    # The window is taken when the write is recorded, so a fold that runs in a
    # later window must not move the count there.
    it "keeps a pending event recorded at 12:04:59 in the 12:00 window when it is folded after that window ends" do
      record_write_metric_at(window_noon + 299)

      travel_to(window_noon + 600) { described_class.fold_pending }

      expect(WriteMetricWindow.where(company_id: company_a).pluck(:window_start, :writes)).to eq([[window_noon, 1]])
    end

    describe "around a held window row" do
      include_context "timekeeping entry writes without transactional fixtures"

      # Holds company_id's window row FOR UPDATE on its own connection until
      # the returned release queue is pushed. Returns the holder thread, the
      # release queue and the holder's server process id.
      def hold_pending_window_row(company_id)
        held = Queue.new
        release = Queue.new
        holder_pid = Queue.new
        holder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do |connection|
            holder_pid << connection.select_value("SELECT pg_backend_pid()")
            connection.transaction do
              connection.execute(ApplicationRecord.sanitize_sql_array(
                ["SELECT 1 FROM write_metric_windows WHERE company_id = ? FOR UPDATE", company_id]
              ))
              held << true
              release.pop(timeout: 10)
            end
          end
        end
        expect(held.pop(timeout: 10)).to be(true)
        [holder, release, holder_pid.pop(timeout: 10)]
      end

      def pending_fold_blocked_by?(waiting_pid, holding_pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          blocked = ApplicationRecord.connection.select_value(
            ApplicationRecord.sanitize_sql_array(["SELECT ? = ANY(pg_blocking_pids(?))", holding_pid, waiting_pid])
          )
          return true if blocked

          sleep 0.02
        end
        false
      end

      # Does a locked metric row delay an entry response after the entry
      # transaction commits? record runs on the entry response path, so it must
      # not wait for the holder to release the counter row.
      it "returns from record while the company's window row is held and keeps that event until a fold after release" do
        record_write_metric_at(window_noon + 30, company_id: 303)
        described_class.fold_pending

        holder, release, = hold_pending_window_row(303)
        recorder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            record_write_metric_at(window_noon + 30, company_id: 303, outcome: :reference_unavailable, latency_ms: 20)
          end
        end
        finished_while_held = recorder.join(3)
        pending_while_held = WriteMetricEvent.where(company_id: 303).count
        writes_while_held = WriteMetricWindow.find_by!(company_id: 303).writes
        release << true
        holder.join(10)
        recorder.join(10)

        expect(finished_while_held).not_to be_nil, "record waited on the held window row"
        expect([pending_while_held, writes_while_held]).to eq([1, 1])
        expect(described_class.fold_pending).to eq(1)
        expect(pending_window_row(303).first(3)).to eq([1, 1, 30])
      end

      # "preserves counts rather than discarding timed-out events"
      it "keeps a held company's events through a fold timeout, folds other companies, and counts the kept event once after release" do
        stub_const("Timekeeping::WriteMetrics::LOCK_TIMEOUT_MS", 1000)
        record_write_metric_at(window_noon + 30, company_id: 404, latency_ms: 10)
        described_class.fold_pending
        record_write_metric_at(window_noon + 30, company_id: 404, latency_ms: 40)
        record_write_metric_at(window_noon + 30, company_id: 505, outcome: :reference_unavailable, latency_ms: 40)

        holder, release, holding_pid = hold_pending_window_row(404)
        folder_pid = Queue.new
        folder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do |connection|
            folder_pid << connection.select_value("SELECT pg_backend_pid()")
            described_class.fold_pending
          end
        end
        blocked = pending_fold_blocked_by?(folder_pid.pop(timeout: 10), holding_pid)
        folded_while_held = folder.join(10)&.value
        pending_while_held = WriteMetricEvent.where(company_id: 404).count
        writes_while_held = WriteMetricWindow.find_by!(company_id: 404).writes
        release << true
        holder.join(10)

        expect(blocked).to be(true), "the fold never waited on the held row"
        expect(folded_while_held).to eq(1)
        expect([pending_while_held, writes_while_held]).to eq([1, 1])
        expect(pending_window_row(505).first(2)).to eq([0, 1])

        expect(described_class.fold_pending).to eq(1)
        expect(pending_window_row(404)).to eq([2, 0, 50, { "25" => 1, "50" => 1 }])
        expect(WriteMetricEvent.count).to eq(0)
        expect(described_class.fold_pending).to eq(0)
        expect(WriteMetricWindow.find_by!(company_id: 404).writes).to eq(2)
      end

      it "answers folded_windows while one company's row is held and includes that company's kept event once the lock clears" do
        record_write_metric_at(window_noon + 60, company_id: 404)
        described_class.folded_windows.to_a

        holder, release, = hold_pending_window_row(404)
        record_write_metric_at(window_noon + 60, company_id: 404)
        record_write_metric_at(window_noon + 60, company_id: 505)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        during = described_class.folded_windows.to_a.to_h { |row| [row.company_id, row.writes] }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        release << true
        holder.join(10)

        expect(elapsed).to be < 5
        expect(during).to eq(404 => 1, 505 => 1)
        after = described_class.folded_windows.to_a.to_h { |row| [row.company_id, row.writes] }
        expect(after).to eq(404 => 2, 505 => 1)
        expect(described_class.folded_windows.to_a.to_h { |row| [row.company_id, row.writes] }).to eq(after)
        expect(WriteMetricEvent.count).to eq(0)
      end
    end

    describe "on more than one connection" do
      include_context "timekeeping entry writes without transactional fixtures"

      # Two metrics reads can fold at the same moment; between them each pending
      # event must be added exactly once.
      it "counts every event once when two connections fold at the same time" do
        5.times { record_write_metric_at(window_noon) }

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
        expect(WriteMetricWindow.where(company_id: company_a).sum(:writes)).to eq(5)
        expect(WriteMetricEvent.count).to eq(0)
      end

      # The pooled connection goes on to serve entry writes; a metric-sized lock
      # timeout left on it would cancel those writes.
      it "leaves the connection's lock_timeout as it was after record and fold_pending" do
        before = ApplicationRecord.connection.select_value("SHOW lock_timeout")

        record_write_metric_at(window_noon)
        described_class.fold_pending

        expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq(before)
        expect(WriteMetricWindow.find_by!(company_id: company_a).writes).to eq(1)
      end
    end
  end
end

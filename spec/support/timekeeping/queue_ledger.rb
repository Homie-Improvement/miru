# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

# The queue ledger proves that no job from a non-dedicated queue executed
# during a live Timekeeping proof run. The Solid Queue tables are emptied on
# every database reset, so what the ledger finds is kept in a JSON file
# outside the cleaned tables, and the run is judged from that file.
#
# This part is the pure core: the dedicated queues, the record shapes, the
# verdict and the file format.
module TimekeepingQueueLedger
  # Queues the demo runtime's workers are allowed to run, per database, as
  # spec/timekeeping/runtime_queues_spec.rb has them. The monolith runs the
  # invoice operation worker and its relay; Timekeeping runs only its relay.
  DEDICATED_QUEUES = {
    "monolith" => %w[invoice_operations timekeeping_relay].freeze,
    "timekeeping" => %w[timekeeping_relay].freeze
  }.freeze

  # Only identifiers and timestamps are kept. Job arguments and a failed
  # execution's error text can hold customer data or connection strings, so
  # they never reach the file.
  Record = Data.define(:database, :queue, :job_class, :kind, :job_id, :active_job_id, :execution_id,
                       :created_at, :finished_at)

  # status is "unrun", "ran" or "missing" once checked, and nil before. A
  # control is found by its active_job_id: a reset that restarts the id
  # sequence can give its integer job_id to a different job.
  Control = Data.define(:queue, :job_class, :job_id, :active_job_id, :status)

  Verdict = Data.define(:failures) do
    def passed?
      failures.empty?
    end
  end

  class UnreadableLedger < StandardError; end

  UNRUN = "unrun"

  module_function

  def verdict(records:, controls:, dedicated_queues:)
    control_ids = controls.to_set(&:active_job_id)
    ran_ids = records.filter_map { |record| record.active_job_id if control_ids.include?(record.active_job_id) }.to_set
    control_failures = controls.filter_map { |control| control_failure(control, ran_ids) }
    execution_failures = records.filter_map do |record|
      next if control_ids.include?(record.active_job_id)

      execution_failure(record, dedicated_queues)
    end
    Verdict.new(failures: (control_failures + execution_failures).uniq.freeze)
  end

  def parse(text)
    document = JSON.parse(text)
    raise UnreadableLedger, "the queue ledger is not an object with records and controls" unless ledger_shape?(document)

    {
      records: document.fetch("records").map { |fields| Record.new(**fields.transform_keys(&:to_sym)) }.freeze,
      controls: document.fetch("controls").map { |fields| Control.new(**fields.transform_keys(&:to_sym)) }.freeze
    }.freeze
  rescue JSON::ParserError, ArgumentError, TypeError
    raise UnreadableLedger, "the queue ledger file cannot be parsed", cause: nil
  end

  def serialize(records:, controls:)
    JSON.generate(
      "records" => records.map { |record| json_fields(record) },
      "controls" => controls.map { |control| json_fields(control) }
    )
  end

  # Adds to what the file already holds. The new content goes to a temp file
  # in the same directory, then a rename replaces the ledger in one step, so a
  # crash mid-write never leaves a half-written ledger behind.
  def write(path, records:, controls:)
    stored = File.exist?(path) ? parse(File.read(path)) : { records: [], controls: [] }
    merged_records = (stored[:records] + records).uniq { |record| record_key(record) }
    FileUtils.mkdir_p(File.dirname(path))
    temp_path = "#{path}.#{Process.pid}.tmp"
    File.write(temp_path, serialize(records: merged_records, controls: merge_controls(stored[:controls], controls)))
    File.rename(temp_path, path)
    nil
  ensure
    FileUtils.rm_f(temp_path) if temp_path
  end

  def control_failure(control, ran_ids)
    status = ran_ids.include?(control.active_job_id) ? "ran" : control.status
    return if status == UNRUN

    problem = status.nil? ? "was never checked" : status
    "control #{control.job_class} on #{control.queue} (active_job_id #{control.active_job_id}) #{problem}"
  end

  def execution_failure(record, dedicated_queues)
    return if dedicated_queues.fetch(record.database, []).include?(record.queue)

    "#{record.kind} execution of #{record.job_class} on non-dedicated queue #{record.queue} in #{record.database} " \
      "(job_id #{record.job_id}, active_job_id #{record.active_job_id})"
  end

  def ledger_shape?(document)
    document.is_a?(Hash) &&
      %w[records controls].all? { |key| document[key].is_a?(Array) && document[key].all?(Hash) }
  end

  def json_fields(value)
    value.to_h.transform_values { |field| field.respond_to?(:iso8601) ? field.utc.iso8601(6) : field }
  end

  # The same execution can be collected at more than one reset.
  def record_key(record)
    [record.database, record.kind, record.active_job_id, record.execution_id]
  end

  # A later check of the same control replaces the earlier one.
  def merge_controls(stored, added)
    by_id = stored.index_by(&:active_job_id)
    added.each { |control| by_id[control.active_job_id] = control }
    by_id.values
  end
  private_class_method :control_failure, :execution_failure, :ledger_shape?, :json_fields, :record_key,
                       :merge_controls
end

# frozen_string_literal: true

require "rake"

# Runs the timekeeping:alerts task the way every task spec needs it: with the
# Timekeeping base URL and service token set, and with stdout, stderr and the
# Rails loggers captured, so a spec can assert on each and on the exit status.
module TimekeepingAlertsTaskHelpers
  include ActiveSupport::Testing::TimeHelpers

  ALERTS_TASK_NAME = "timekeeping:alerts"

  # exit_status is nil when the task finished without calling exit or abort.
  TimekeepingAlertsTaskRun = Data.define(:stdout, :stderr, :log, :exit_status) do
    # The company_id of every alert line with this name, parsed from the
    # Timekeeping::AlertLog.alert_line format.
    def alert_company_ids(name)
      stdout.lines.filter_map { |line| line[/\Atimekeeping alert name=#{name} company_id=(\S+) /, 1] }
    end
  end

  # metrics: a Hash is answered as the 200 body of the metrics read for this
  # token; nil stubs nothing, so the caller stubs the read or a real server
  # answers it. now: runs the task at that time; nil keeps the real clock.
  def run_timekeeping_alerts_task(base_url:, token:, now: nil, metrics: nil)
    stub_timekeeping_alerts_task_metrics(base_url:, token:, body: metrics) if metrics
    return travel_to(now) { run_timekeeping_alerts_task(base_url:, token:) } if now

    Rails.application.load_tasks unless Rake::Task.task_defined?(ALERTS_TASK_NAME)
    # Rake runs an invoked task only once until it is reenabled.
    Rake::Task[ALERTS_TASK_NAME].reenable

    stdout = StringIO.new
    stderr = StringIO.new
    log = StringIO.new
    exit_status = nil
    env = {
      Timekeeping::EntryApiClient::BASE_URL_ENV => base_url,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV => token
    }

    capture_logger = ActiveSupport::Logger.new(log).tap { |logger| logger.level = Logger::DEBUG }

    with_timekeeping_alerts_task_output(stdout:, stderr:, logger: capture_logger) do
      with_timekeeping_env(env) { Rake::Task[ALERTS_TASK_NAME].invoke }
    rescue SystemExit => e
      exit_status = e.status
    end

    TimekeepingAlertsTaskRun.new(stdout: stdout.string, stderr: stderr.string, log: log.string, exit_status:)
  end

  private

    def stub_timekeeping_alerts_task_metrics(base_url:, token:, body:)
      stub_request(:get, "#{base_url}/internal/v1/metrics")
        .with(headers: { "Authorization" => "Bearer #{token}" })
        .to_return(status: 200, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
    end

    # The task aborts with SystemExit on a failed metrics read, so every stream
    # and logger is put back in ensure; otherwise later examples would write into
    # this run's buffers.
    def with_timekeeping_alerts_task_output(stdout:, stderr:, logger:)
      loggers_before = [Rails.logger, ActionController::Base.logger, ActionController::API.logger]
      stdout_before = $stdout
      stderr_before = $stderr
      Rails.logger = ActionController::Base.logger = ActionController::API.logger = logger
      $stdout = stdout
      $stderr = stderr
      yield
    ensure
      $stdout = stdout_before
      $stderr = stderr_before
      Rails.logger, ActionController::Base.logger, ActionController::API.logger = loggers_before
    end
end

RSpec.configure do |config|
  config.include TimekeepingAlertsTaskHelpers
end

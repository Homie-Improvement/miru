# frozen_string_literal: true

require "rake"

# Runs the timekeeping:alerts task the way every task spec needs it: with the
# Timekeeping base URL and service token set, and with stdout, stderr and the
# Rails loggers captured, so a spec can assert on each and on the exit status.
module TimekeepingAlertsTaskHelpers
  ALERTS_TASK_NAME = "timekeeping:alerts"

  # exit_status is nil when the task finished without calling exit or abort.
  TimekeepingAlertsTaskRun = Data.define(:stdout, :stderr, :log, :exit_status)

  def run_timekeeping_alerts_task(base_url:, token:)
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

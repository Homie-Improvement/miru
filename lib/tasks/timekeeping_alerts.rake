# frozen_string_literal: true

namespace :timekeeping do
  desc "Report the docs/architecture/timekeeping-soa.md section 11.3 alerts (TIMEKEEPING_BASE_URL and TIMEKEEPING_SERVICE_TOKEN required)"
  task alerts: :environment do
    signals = Timekeeping::AlertSignals.gather(now: Time.current, metrics_client: Timekeeping::MetricsClient.configured)
    alerts = Timekeeping::Alerts.evaluate(signals)

    alerts.each do |alert|
      Rails.logger.warn(alert.log_line)
      puts alert.log_line
    end
    puts "no alerts" if alerts.empty?

    unsourced = Timekeeping::Alerts.unsourced(signals)
    puts "signals not sourced: #{unsourced.join(", ")}" if unsourced.any?
  rescue Timekeeping::MetricsClient::Unavailable => error
    # A refused or unreachable endpoint must fail the run, never look like a
    # healthy one with nothing to report.
    abort "timekeeping alerts not evaluated: #{error.message}"
  end
end

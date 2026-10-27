# frozen_string_literal: true

namespace :timekeeping do
  desc "Log every docs/architecture/timekeeping-soa.md section 11.3 alert (TIMEKEEPING_BASE_URL and TIMEKEEPING_SERVICE_TOKEN required)"
  task alerts: :environment do
    gathered = Timekeeping::AlertSignals.gather(metrics_client: Timekeeping::MetricsClient.new, now: Time.current)

    Timekeeping::Alerts.evaluate(gathered[:signals]).each do |alert|
      line = Timekeeping::AlertLog.alert_line(alert)
      Rails.logger.warn(line)
      puts line
    end
    gathered[:unavailable].each { |name| puts Timekeeping::AlertLog.unavailable_line(name) }

    failures = []
    failures << Timekeeping::AlertLog.metrics_error_line(gathered[:metrics_error]) if gathered[:metrics_error]
    if gathered[:failed_local_reads].any?
      failures << Timekeeping::AlertLog.failed_local_reads_line(gathered[:failed_local_reads])
    end
    abort failures.join("\n") if failures.any?
  end
end

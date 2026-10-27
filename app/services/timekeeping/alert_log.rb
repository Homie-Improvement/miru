# frozen_string_literal: true

module Timekeeping
  # The lines the timekeeping:alerts task prints. An alert line carries only
  # the alert name, the company, the measured value and the threshold, never
  # entry, user or money figures from the signals. An alert that belongs to no
  # one company (the global write fence) shows company_id=all.
  module AlertLog
    ALL_COMPANIES = "all"

    module_function

    def alert_line(alert)
      "timekeeping alert name=#{alert.name} company_id=#{alert.company_id || ALL_COMPANIES} " \
        "value=#{format_number(alert.value)} threshold=#{format_number(alert.threshold)}"
    end

    def unavailable_line(name)
      "timekeeping alert unavailable signal=#{name}"
    end

    def metrics_error_line(message)
      "timekeeping alerts: the Timekeeping metrics read failed (#{message})"
    end

    def failed_local_reads_line(names)
      "timekeeping alerts: the local read failed for #{names.join(', ')}"
    end

    # Rates arrive as Rationals and a p95 past every bucket bound as Infinity.
    def format_number(value)
      case value
      when Rational, Float then value.infinite? ? "inf" : value.to_f.round(4).to_s
      else value.to_s
      end
    end
  end
end

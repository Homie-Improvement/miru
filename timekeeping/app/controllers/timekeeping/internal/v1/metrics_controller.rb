# frozen_string_literal: true

# Per-company entry write metrics for the alert evaluator. The body holds
# every company's counts, so only the service identity may read it. Entry
# writes only leave pending metric events; each read first adds the pending
# events it can into the windows. A company whose window row is held, or
# whose events another read is already adding, keeps them pending, and a
# later read counts them.
class Timekeeping::Internal::V1::MetricsController < Timekeeping::Internal::V1::ServiceController
  def index
    render json: Timekeeping::WriteMetricsPresenter.call(Timekeeping::WriteMetrics.folded_windows)
  end
end

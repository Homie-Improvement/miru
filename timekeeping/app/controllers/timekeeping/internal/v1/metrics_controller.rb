# frozen_string_literal: true

# Per-company entry write metrics for the alert evaluator. The body holds
# every company's counts, so only the service identity may read it.
class Timekeeping::Internal::V1::MetricsController < ApplicationController
  skip_before_action :authorize_read!
  before_action :authorize_service!

  def index
    windows = WriteMetricWindow.order(:company_id, :window_start)
    render json: Timekeeping::WriteMetricsPresenter.call(windows)
  end

  private

    def authorize_service!
      decision = Timekeeping::ServiceAccess.decide(identity)
      render_reason(decision) unless decision == :allowed
    end
end

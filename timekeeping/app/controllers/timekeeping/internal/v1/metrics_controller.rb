# frozen_string_literal: true

# Per-company entry write metrics for the alert evaluator. The body holds
# every company's counts, so only the service identity may read it. Entry
# writes only leave pending metric events; each read adds them into the
# windows first, so a write is counted on the first read after it.
class Timekeeping::Internal::V1::MetricsController < ApplicationController
  skip_before_action :authorize_read!
  before_action :authorize_service!

  def index
    render json: Timekeeping::WriteMetricsPresenter.call(Timekeeping::WriteMetrics.folded_windows)
  end

  private

    def authorize_service!
      decision = Timekeeping::ServiceAccess.decide(identity)
      render_reason(decision) unless decision == :allowed
    end
end

# frozen_string_literal: true

require "action_controller/log_subscriber"

module Timekeeping
  # ActionController's log subscriber, except that the "Parameters:" line masks
  # parameter names outside Timekeeping::LogSafety's allow-list. The parameter
  # filter masks only values, so a token sent as a parameter name would
  # otherwise be logged.
  class ControllerLogSubscriber < ActionController::LogSubscriber
    def start_processing(event)
      return unless logger.info?

      payload = event.payload
      params = payload[:params].except(*INTERNAL_PARAMS)
      format = payload[:format]
      format = format.to_s.upcase if format.is_a?(Symbol)
      format = "*/*" if format.nil?

      info "Processing by #{payload[:controller]}##{payload[:action]} as #{format}"
      info "  Parameters: #{LogSafety.loggable_params(params).inspect}" unless params.empty?
    end
  end
end

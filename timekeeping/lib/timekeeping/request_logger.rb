# frozen_string_literal: true

module Timekeeping
  # Rails::Rack::Logger, except that the request start line shows only what
  # Timekeeping::LogSafety approved. Rails masks only query values there, so a
  # token sent as the method, a path segment or a parameter name would reach
  # the log.
  class RequestLogger < Rails::Rack::Logger
    private

      def started_request_message(request)
        path = LogSafety.loggable_path(request.path)
        path = "#{path}?#{LogSafety.loggable_query(request.query_string)}" unless request.query_string.empty?
        sprintf('Started %s "%s" for %s at %s',
          LogSafety.loggable_method(request.raw_request_method),
          path,
          request.remote_ip,
          Time.now)
      end
  end
end

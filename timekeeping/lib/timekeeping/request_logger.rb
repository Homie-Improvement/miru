# frozen_string_literal: true

module Timekeeping
  # Rails::Rack::Logger, except that the request start line logs a path whose
  # segments Timekeeping::LogSafety approved. Rails masks only the query string
  # there, so a token sent as a company or entry id would reach the log.
  class RequestLogger < Rails::Rack::Logger
    private

      def started_request_message(request)
        query = request.filtered_path.delete_prefix(request.path)
        sprintf('Started %s "%s" for %s at %s',
          request.raw_request_method,
          "#{LogSafety.loggable_path(request.path)}#{query}",
          request.remote_ip,
          Time.now)
      end
  end
end

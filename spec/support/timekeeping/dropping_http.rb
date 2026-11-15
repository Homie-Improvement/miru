# frozen_string_literal: true

module TimekeepingContract
  # Simulates a response lost on the way back from Timekeeping. Every call is
  # forwarded to the wrapped http, so the fake really applies it; when
  # drop.call(method, path) is true the answer is thrown away and the caller
  # sees Timekeeping::ReservationHttp::Error, as it would after a timeout.
  class DroppingHttp
    def initialize(http, drop:)
      @http = http
      @drop = drop
    end

    def call(method, path, headers: {}, body: nil)
      response = @http.call(method, path, headers:, body:)
      raise Timekeeping::ReservationHttp::Error, "Timekeeping #{method.to_s.upcase} #{path} answer dropped" if @drop.call(method, path)

      response
    end
  end
end

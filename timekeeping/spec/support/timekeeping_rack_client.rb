# frozen_string_literal: true

# The timekeeping_client the shared contract examples call: each request goes
# through the real Rack app, middleware included, and the answer comes back as
# the TimekeepingContract::Response the examples read.
class TimekeepingRackClient
  def initialize(app)
    @app = app
  end

  def call(method, path, headers: {}, body: nil)
    env = headers.to_h.transform_keys { |name| "HTTP_#{name.to_s.upcase.tr("-", "_")}" }
    env["CONTENT_TYPE"] = "application/json"
    env[:input] = JSON.generate(body) unless body.nil?
    response = Rack::MockRequest.new(@app).request(method, path, env)
    TimekeepingContract::Response.new(status: response.status, body: response.body.empty? ? nil : JSON.parse(response.body))
  end
end

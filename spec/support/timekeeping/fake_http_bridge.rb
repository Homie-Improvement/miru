# frozen_string_literal: true

require "json"
require "uri"

require_relative "fake_timekeeping"

module TimekeepingContract
  # Answers every HTTP request to base_url from a FakeTimekeeping, so the
  # monolith's real Timekeeping clients run unchanged and the fake sees the
  # token, headers and body they actually build.
  module FakeHttpBridge
    def route_timekeeping_to_fake(fake, base_url:)
      target = URI.parse(base_url)
      stub_request(:any, ->(uri) { uri.host == target.host && uri.port == target.port }).to_return do |request|
        body = request.body.to_s.empty? ? nil : JSON.parse(request.body)
        answer = fake.call(request.method.to_s.upcase, request.uri.request_uri, headers: request.headers, body:)
        { status: answer.status, body: JSON.generate(answer.body), headers: { "Content-Type" => "application/json" } }
      end
    end
  end
end

RSpec.configure do |config|
  config.include TimekeepingContract::FakeHttpBridge
end

# frozen_string_literal: true

require "json"
require "uri"

module TimekeepingContract
  # What every implementation under the contract examples answers: an HTTP
  # status and a JSON body parsed into string-keyed Hashes and Arrays.
  Response = Struct.new(:status, :body, keyword_init: true)

  # Passes values through JSON, so the fakes accept and return only what the
  # wire carries: string keys, and floats that stay floats.
  module Wire
    def self.copy(value)
      value.nil? ? nil : JSON.parse(JSON.generate(value))
    end

    # The error answer a contract names, for example error(reservations, "not_found").
    def self.error(contract, name)
      error = contract.fetch("errors").fetch(name)
      Response.new(status: error.fetch("status"), body: copy(error.fetch("body")))
    end

    def self.bearer(headers)
      credential = headers.to_h["Authorization"].to_s.delete_prefix("Bearer ")
      credential.empty? ? nil : credential
    end
  end

  # Matches a request against a contract's route table. A path template such
  # as /v1/companies/{company_id}/entries becomes a pattern with named
  # captures; the query string is added to the captured params.
  class Router
    def initialize(routes)
      @routes = routes.map do |name, route|
        [name, route.fetch("method"), pattern(route.fetch("path"))]
      end
    end

    # Returns [route name, params] or nil when no route matches.
    def match(method, path)
      route_path, query = path.split("?", 2)
      @routes.each do |name, route_method, regex|
        next unless route_method == method.to_s.upcase

        captures = regex.match(route_path)&.named_captures
        return [name, captures.merge(URI.decode_www_form(query.to_s).to_h)] if captures
      end
      nil
    end

    private

      def pattern(template)
        Regexp.new("\\A#{Regexp.escape(template).gsub(/\\\{(\w+)\\\}/, '(?<\1>[^/]+)')}\\z")
      end
  end

  # The client the fakes hand to the shared examples. Snapshot deliveries go to
  # the monolith's projection endpoint (the fake relay); every other route goes
  # to Timekeeping.
  class FakeClient
    SNAPSHOT_PATH_PREFIX = "/internal/"

    def initialize(timekeeping:, relay:)
      @timekeeping = timekeeping
      @relay = relay
    end

    def call(method, path, headers: {}, body: nil)
      target = path.start_with?(SNAPSHOT_PATH_PREFIX) ? @relay : @timekeeping
      target.call(method, path, headers:, body:)
    end
  end
end

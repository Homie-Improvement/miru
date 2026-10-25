# frozen_string_literal: true

module Timekeeping
  # Resolves the caller once per request and stores the result in the Rack
  # env. It runs before Rails::Rack::Logger, so the request start and end lines
  # are tagged with the verified company and actor kind, not only the lines a
  # controller writes.
  class RequestIdentity
    ENV_KEY = "timekeeping.identity"
    UNVERIFIED_COMPANY = "unverified"

    def self.from(env)
      env.fetch(ENV_KEY) { Identity.anonymous(:missing) }
    end

    # Rails.application.config.log_tags: each proc receives the request.
    LOG_TAGS = [
      ->(request) { "company_id=#{from(request.env).company_id || UNVERIFIED_COMPANY}" },
      ->(request) { "request_id=#{LogSafety.request_id_tag(request.request_id)}" },
      ->(request) { "actor=#{from(request.env).kind}" }
    ].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      env[ENV_KEY] = Identity.resolve(
        authorization: env["HTTP_AUTHORIZATION"],
        public_key: Environment.token_public_key,
        service_token: Environment.service_token
      )
      @app.call(env)
    end
  end
end

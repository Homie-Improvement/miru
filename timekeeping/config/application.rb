# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

require_relative "../lib/timekeeping/environment"
require_relative "../lib/timekeeping/token_verifier"
require_relative "../lib/timekeeping/identity"
require_relative "../lib/timekeeping/log_safety"
require_relative "../lib/timekeeping/request_identity"

module TimekeepingService
  class Application < Rails::Application
    config.load_defaults 8.1

    # A JSON API: no cookies, sessions, views or assets.
    config.api_only = true

    config.middleware.insert_before Rails::Rack::Logger, Timekeeping::RequestIdentity
    config.log_tags = Timekeeping::RequestIdentity::LOG_TAGS
  end
end

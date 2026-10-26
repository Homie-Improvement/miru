# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

require_relative "../lib/timekeeping/environment"
require_relative "../lib/timekeeping/token_verifier"
require_relative "../lib/timekeeping/service_token_verifier"
require_relative "../lib/timekeeping/identity"
require_relative "../lib/timekeeping/log_safety"
require_relative "../lib/timekeeping/request_identity"
require_relative "../lib/timekeeping/request_logger"
require_relative "../lib/timekeeping/controller_log_subscriber"

module TimekeepingService
  class Application < Rails::Application
    config.load_defaults 8.1

    # A JSON API: no cookies, sessions, views or assets.
    config.api_only = true

    config.log_tags = Timekeeping::RequestIdentity::LOG_TAGS
    config.middleware.swap Rails::Rack::Logger, Timekeeping::RequestLogger, config.log_tags
    config.middleware.insert_before Timekeeping::RequestLogger, Timekeeping::RequestIdentity

    # A routing error's log line repeats the raw path, which may hold a token
    # sent in place of an id. The 404 it answers needs no log line.
    config.action_dispatch.log_rescued_responses = false

    ActionController::LogSubscriber.detach_from :action_controller
    Timekeeping::ControllerLogSubscriber.attach_to :action_controller, inherit_all: true
  end
end

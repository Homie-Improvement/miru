# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

require_relative "../lib/timekeeping/environment"

module TimekeepingService
  class Application < Rails::Application
    config.load_defaults 8.1

    # A JSON API: no cookies, sessions, views or assets.
    config.api_only = true
  end
end

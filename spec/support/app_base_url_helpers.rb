# frozen_string_literal: true

# AppBaseUrl.current reads ENV["APP_BASE_URL"] and falls back to
# Rails.configuration.x.default_base_url. Both are process-wide, so a spec that
# changes them must put them back or it changes what later examples see.
module AppBaseUrlHelpers
  # Sets both base URL sources for the duration of the block, then restores
  # their previous values, also when the block raises. A nil env removes
  # APP_BASE_URL so the default is what AppBaseUrl.current returns.
  def with_app_base_url(env:, default:, &block)
    previous_env = ENV.fetch("APP_BASE_URL", nil)
    previous_default = Rails.configuration.x.default_base_url
    ENV["APP_BASE_URL"] = env
    Rails.configuration.x.default_base_url = default
    block.call
  ensure
    ENV["APP_BASE_URL"] = previous_env
    Rails.configuration.x.default_base_url = previous_default
  end
end

RSpec.configure do |config|
  config.include AppBaseUrlHelpers
end

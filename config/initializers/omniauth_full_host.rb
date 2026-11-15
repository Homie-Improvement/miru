# frozen_string_literal: true

require "omniauth"

# OmniAuth builds OAuth callback URLs from `full_host`. When it is unset, OmniAuth derives the
# host from the request's Host and X-Forwarded-* headers, so a forged header could send the
# provider's authorization code to another host. This file is the only place that sets
# `full_host`: it pins a fixed string at boot, taken from `AppBaseUrl.current`
# (config/initializers/app_base_url.rb). A string, unlike a lambda, never sees the request, so
# the pin holds even if a later OmniAuth release regresses.
module OmniauthFullHost
  # The same error class as AppBaseUrl's, so every invalid base URL raises one error. The guard
  # lets specs `load` this file again without a constant-redefinition warning.
  InvalidBaseUrl = AppBaseUrl::InvalidBaseUrl unless const_defined?(:InvalidBaseUrl, false)

  # `require_https` is on in production, which forces SSL: an http base URL there would send
  # OAuth codes and emailed links over plain http to a scheme the app redirects away from.
  def self.resolve(app_base_url:, fallback:, require_https: false)
    enforce_https(AppBaseUrl.resolve(app_base_url:, fallback:), require_https:)
  end

  # Takes a base URL AppBaseUrl has already validated, so only the scheme is left to check.
  def self.enforce_https(base_url, require_https:)
    scheme = URI.parse(base_url).scheme
    # Names only the scheme, so a password embedded in the URL stays out of boot logs.
    if require_https && scheme != "https"
      raise InvalidBaseUrl,
        "APP_BASE_URL (or config.x.default_base_url when it is blank) must use https in production, " \
        "got scheme #{scheme.inspect}"
    end

    base_url
  end

  def self.pin!(base_url)
    OmniAuth.config.full_host = base_url
  end
end

OmniauthFullHost.pin!(
  OmniauthFullHost.enforce_https(AppBaseUrl.current, require_https: Rails.env.production?)
)

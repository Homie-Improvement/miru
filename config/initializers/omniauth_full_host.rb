# frozen_string_literal: true

require "omniauth"

# OmniAuth builds OAuth callback URLs from `full_host`. When it is unset, OmniAuth derives the
# host from the request's Host and X-Forwarded-* headers, so a forged header could send the
# provider's authorization code to another host. This file is the only place that sets
# `full_host`: it pins a fixed string at boot, taken from `AppBaseUrl.current`
# (config/initializers/app_base_url.rb). A string, unlike a lambda, never sees the request, so
# the pin holds even if a later OmniAuth release regresses.
module OmniauthFullHost
  def self.pin!(base_url)
    OmniAuth.config.full_host = base_url
  end
end

OmniauthFullHost.pin!(AppBaseUrl.current)

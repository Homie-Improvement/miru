# frozen_string_literal: true

require "omniauth"

# OmniAuth builds OAuth callback URLs from `full_host`. When it is unset, OmniAuth derives the
# host from the request's Host and X-Forwarded-* headers, so a forged header could send the
# provider's authorization code to another host. This file is the only place that sets
# `full_host`: it pins a fixed string at boot, taken from APP_BASE_URL when that is non-blank and
# from the environment's required `config.x.default_base_url` otherwise. A string, unlike a
# lambda, never sees the request, so the pin holds even if a later OmniAuth release regresses.
module OmniauthFullHost
  # Declared as a class reopening, not a constant assignment, so specs can `load` this file
  # again without a constant-redefinition warning.
  class InvalidBaseUrl < StandardError; end

  def self.resolve(app_base_url:, fallback:)
    source, base_url = if app_base_url.present?
      ["APP_BASE_URL", app_base_url]
    else
      ["config.x.default_base_url", fallback]
    end

    validate!(source, base_url.to_s.strip)
  end

  def self.pin!(base_url)
    OmniAuth.config.full_host = base_url
  end

  def self.validate!(source, base_url)
    uri = URI.parse(base_url)
    unless %w[http https].include?(uri.scheme) && uri.host.present?
      raise InvalidBaseUrl, "#{source} must be an absolute http or https URL with a host, got #{base_url.inspect}"
    end

    # OmniAuth appends the callback path to full_host, so a trailing slash would double it.
    base_url.sub(%r{/+\z}, "")
  rescue URI::InvalidURIError
    raise InvalidBaseUrl, "#{source} is not a valid URL, got #{base_url.inspect}"
  end
  private_class_method :validate!
end

OmniauthFullHost.pin!(
  OmniauthFullHost.resolve(app_base_url: ENV["APP_BASE_URL"], fallback: Rails.configuration.x.default_base_url)
)

# frozen_string_literal: true

# The one place that decides the app's base URL for links and callbacks: APP_BASE_URL when it is
# non-blank, otherwise the environment's required `config.x.default_base_url`. OmniAuth, the
# QuickBooks configuration, the MCP API proxy, the Stripe Connect onboarding links, the mailers and
# their views call `AppBaseUrl.current` so none keeps its own fallback.
#
# It lives in an initializer rather than lib/ because lib/ is reloadable, and Rails refuses
# reloadable constants during boot, while config/initializers/omniauth_full_host.rb needs it then.
# Initializers load in file-name order, so this file runs before that one.
module AppBaseUrl
  # Declared as a class reopening, not a constant assignment, so specs can `load` this file
  # again without a constant-redefinition warning.
  class InvalidBaseUrl < StandardError; end

  # Reads ENV and the setting on every call, so a changed APP_BASE_URL (or a spec's stub of it)
  # takes effect without a reboot.
  def self.current
    resolve(app_base_url: ENV["APP_BASE_URL"], fallback: Rails.configuration.x.default_base_url)
  end

  def self.resolve(app_base_url:, fallback:)
    source, base_url = if app_base_url.present?
      ["APP_BASE_URL", app_base_url]
    else
      ["config.x.default_base_url", fallback]
    end

    validate!(source, base_url.to_s.strip)
  end

  def self.validate!(source, base_url)
    uri = URI.parse(base_url)
    unless %w[http https].include?(uri.scheme) && uri.host.present?
      raise InvalidBaseUrl, "#{source} must be an absolute http or https URL with a host, got #{base_url.inspect}"
    end

    # Readers append paths to the base URL, so a trailing slash would double it.
    base_url.sub(%r{/+\z}, "")
  rescue URI::InvalidURIError
    raise InvalidBaseUrl, "#{source} is not a valid URL, got #{base_url.inspect}"
  end
  private_class_method :validate!
end

# Resolve once at boot so a malformed value stops the app before any reader uses it.
AppBaseUrl.current

# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # Rails refuses to boot without a secret_key_base, but this API signs no
  # cookie, session or message with it. A fresh random value per process keeps
  # the service's four keys its only settings and leaves no secret to store.
  config.secret_key_base = SecureRandom.hex(64)

  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = :info

  config.active_support.report_deprecations = false
  config.active_record.dump_schema_after_migration = false
end

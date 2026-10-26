# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr

  # Slows every entry write by TIMEKEEPING_TEST_WRITE_DELAY_MS, so an
  # end-to-end spec can raise real write latency. Only this environment sets
  # the checkpoint, so production writes can never be slowed this way.
  write_delay_ms = ENV["TIMEKEEPING_TEST_WRITE_DELAY_MS"].presence
  if write_delay_ms
    write_delay_seconds = Integer(write_delay_ms) / 1000.0
    config.x.entry_write_checkpoint = ->(step) { sleep(write_delay_seconds) if step == :entry_written }
  end
end

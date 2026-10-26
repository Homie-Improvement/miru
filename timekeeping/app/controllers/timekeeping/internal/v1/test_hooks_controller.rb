# frozen_string_literal: true

# Pauses and resumes snapshot delivery, and slows entry writes, for the
# integration tests. The routes exist only when Timekeeping::TestHooks is
# loaded. A pause stops every company's entries reaching the monolith and a
# delay slows every company's writes, so only the service identity may call
# them.
class Timekeeping::Internal::V1::TestHooksController < ApplicationController
  # Long enough to push any write past the 300 ms latency alert, short enough
  # that a forgotten delay cannot hold a request open past a client timeout.
  MAX_WRITE_DELAY_MS = 5_000

  skip_before_action :authorize_read!
  before_action :authorize_service!

  def pause
    Timekeeping::TestHooks.pause_relay!
    head 204
  end

  def resume
    Timekeeping::TestHooks.resume_relay!
    head 204
  end

  # Body: { "milliseconds": Integer from 0 to MAX_WRITE_DELAY_MS }.
  def delay_writes
    milliseconds = params[:milliseconds]
    return render_reason(:invalid_request) unless milliseconds.is_a?(Integer) && milliseconds.between?(0, MAX_WRITE_DELAY_MS)

    Timekeeping::TestHooks.delay_writes!(milliseconds)
    head 204
  end

  def clear_write_delay
    Timekeeping::TestHooks.clear_write_delay!
    head 204
  end
end

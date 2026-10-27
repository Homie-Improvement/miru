# frozen_string_literal: true

module Timekeeping
  module Handoff
    # One side of a handoff and the integrations the runner reaches it
    # through: its checkpoint store, the admission adapter that fences and
    # admits its entry writers, and the integrations that settle its invoice
    # operations and drain its outbox. Any of the last three may be nil when
    # it is not configured; Capabilities decides whether that blocks a start.
    Owner = Data.define(:name, :store, :admission, :settle, :drain)
  end
end

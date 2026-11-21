# frozen_string_literal: true

module Timekeeping
  # What an entry write answers: an HTTP status and the exact JSON body sent.
  # The body is kept as JSON text, so a replayed receipt sends the same bytes
  # the first answer sent. replayed is true only for an answer served from a
  # stored receipt, so the caller can tell a replay from a first answer whose
  # status and body are identical (contracts/timekeeping/entry_api.yml
  # headers.idempotency_replayed).
  WriteOutcome = Data.define(:status, :body, :replayed) do
    def self.refusal(reason)
      new(status: Reasons.status(reason), body: JSON.generate(reason: reason.to_s))
    end

    def self.success(status, payload)
      new(status:, body: JSON.generate(payload))
    end

    def initialize(status:, body:, replayed: false)
      super
    end
  end
end

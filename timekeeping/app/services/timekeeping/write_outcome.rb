# frozen_string_literal: true

module Timekeeping
  # What an entry write answers: an HTTP status and the exact JSON body sent.
  # The body is kept as JSON text, so a replayed receipt sends the same bytes
  # the first answer sent.
  WriteOutcome = Data.define(:status, :body) do
    def self.refusal(reason)
      new(status: Reasons.status(reason), body: JSON.generate(reason: reason.to_s))
    end

    def self.success(status, payload)
      new(status:, body: JSON.generate(payload))
    end
  end
end

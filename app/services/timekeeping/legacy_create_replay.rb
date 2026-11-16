# frozen_string_literal: true

module Timekeeping
  # Pure rules for replaying a create in the legacy store by the client's own
  # Idempotency-Key. The gateway looks up the receipt and carries out the
  # answer; this module only fingerprints the request and decides.
  module LegacyCreateReplay
    # The fingerprint covers the request values (target user, project and
    # forwarded fields), never the saved row, because the row also holds
    # defaults read from current state that can change between attempts.
    def self.fingerprint(identity)
      Digest::SHA256.hexdigest(JSON.generate(identity))
    end

    # :write when no receipt exists, :replay when the receipt was stored for
    # the same request, :key_reused when the key was used for another request.
    def self.decision(stored_fingerprint:, fingerprint:)
      return :write if stored_fingerprint.nil?

      stored_fingerprint == fingerprint ? :replay : :key_reused
    end
  end
end

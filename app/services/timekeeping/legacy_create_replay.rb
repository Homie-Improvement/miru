# frozen_string_literal: true

module Timekeeping
  # Pure rules for replaying a create in the legacy store by the client's own
  # Idempotency-Key. The gateway looks up the receipt and carries out the
  # answer; this module only fingerprints the request and decides.
  module LegacyCreateReplay
    # Fixed namespace for the version 5 UUIDs used as carried receipt keys.
    # It differs from EntryWriteClient's, so no client-chosen Idempotency-Key
    # can make an ordinary forwarded create derive a carried key.
    CARRIED_KEY_NAMESPACE = "b6e4c1a2-3f5d-4e7a-9c8b-2d1f0e3a4b5c"

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

    # The fingerprint Timekeeping stores for a create whose request body is
    # wire_body: it hashes the body it parsed, generated again, so whitespace
    # in the text does not count and key order does.
    def self.forwarded_fingerprint(wire_body)
      Digest::SHA256.hexdigest(JSON.generate(JSON.parse(wire_body)))
    end

    # The Idempotency-Key a legacy create's receipt answers to once carried
    # into Timekeeping. Timekeeping scopes receipts by company, user and key
    # only, while legacy receipts are also scoped by actor kind, so the kind
    # is part of the key: a browser create and a command-line create sent with
    # one client key each keep their own receipt.
    def self.carried_key(actor_kind:, key:)
      Digest::UUID.uuid_v5(CARRIED_KEY_NAMESPACE, "#{actor_kind}/#{key}")
    end
  end
end

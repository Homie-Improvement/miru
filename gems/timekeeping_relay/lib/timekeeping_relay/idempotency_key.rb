# frozen_string_literal: true

require "digest/sha1"

module TimekeepingRelay
  # The Idempotency-Key for a batch: a name-based UUID (version 5) over the
  # batch's canonical JSON. Outbox rows are never rewritten, so a resend of the
  # same rows carries the same key and the consumer replays its stored answer.
  # The key covers the whole body, not only positions, because each outbox
  # numbers its own positions: two different batches at the same positions
  # must never share a key, or the consumer would answer one with the other's
  # stored 200 and its rows would be marked sent without being applied.
  module IdempotencyKey
    # A fixed namespace for these keys, so they never collide with name-based
    # UUIDs made for other purposes.
    NAMESPACE = "6f1d4c2a-8b3e-5a7f-9c0d-2e4b6a8c0e1f"
    VERSION_BITS = 0x50
    VARIANT_BITS = 0x80

    module_function

    def for(batch)
      digest = Digest::SHA1.digest(namespace_bytes + BatchJson.generate(BatchJson.canonical(batch)))
      bytes = digest.bytes.first(16)
      bytes[6] = (bytes[6] & 0x0f) | VERSION_BITS
      bytes[8] = (bytes[8] & 0x3f) | VARIANT_BITS
      hex = bytes.pack("C*").unpack1("H*")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def namespace_bytes
      [NAMESPACE.delete("-")].pack("H*")
    end
  end
end

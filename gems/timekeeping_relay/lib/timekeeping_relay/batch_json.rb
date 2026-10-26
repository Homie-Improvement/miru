# frozen_string_literal: true

require "json"

module TimekeepingRelay
  # The one way a batch becomes JSON, shared by the Idempotency-Key and the
  # HTTP body. The consumer fingerprints the body it receives and refuses a
  # reused key whose body differs, so the key must be taken from exactly the
  # text that is posted.
  module BatchJson
    module_function

    # Hash keys turned into strings and sorted at every depth, so the same
    # content always serializes to the same text whatever order a source built
    # it in.
    def canonical(value)
      case value
      when Hash then value.map { |key, item| [key.to_s, canonical(item)] }.sort_by(&:first).to_h
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    # No nesting limit here: the batch envelope adds levels above an entry's
    # metadata, so JSON's default limit of 100 would refuse a row that was
    # admitted and stored, and that row would block every later delivery. The
    # depth is bounded where the entry body was first parsed.
    def generate(batch)
      JSON.generate(batch, max_nesting: false)
    end
  end
end

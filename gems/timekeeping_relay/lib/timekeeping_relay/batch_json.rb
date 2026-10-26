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
      JSON.generate(exact_numbers(batch), max_nesting: false)
    end

    # A BigDecimal goes out as a bare JSON number with every digit. The default
    # encoders write it as a quoted string, or round it through a Float. The gem
    # does not load bigdecimal itself, so the class is looked up only when a
    # source has loaded it.
    def exact_numbers(value)
      case value
      when Hash then value.transform_values { |item| exact_numbers(item) }
      when Array then value.map { |item| exact_numbers(item) }
      else defined?(::BigDecimal) && value.is_a?(::BigDecimal) ? JSON::Fragment.new(value.to_s("F")) : value
      end
    end
    private_class_method :exact_numbers
  end
end

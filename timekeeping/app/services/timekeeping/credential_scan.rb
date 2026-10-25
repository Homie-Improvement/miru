# frozen_string_literal: true

require "set"

module Timekeeping
  # Finds a credential in an entry write's body before anything is stored, so
  # no entry, audit row, receipt or outbox snapshot can carry one. It reads the
  # parsed body, never the raw request text: a JSON escape such as \u0065 hides
  # a token from the raw text, and parsing restores it in the stored value.
  #
  # Pure: the caller's bearer token, the held credentials and the public key
  # are arguments, and nothing is read from ENV.
  module CredentialScan
    # A run of base64url segments joined by dots. A JWT is three of them.
    DOTTED_SEGMENTS = /[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+/
    # Every JWT header is a JSON object, and base64url of '{"' starts with this.
    JWT_HEADER_START = "eyJ"
    JWT_SEGMENT_COUNT = 3

    module_function

    # True when the body holds, anywhere, the bearer token, a held credential,
    # or a string whose signature verifies as a user token. A token that fails
    # only on exp still counts: its signature verifies, so it was issued.
    def found?(parsed_body, bearer:, held:, public_key:)
      texts = [JSON.generate(parsed_body), *decoded_strings(parsed_body)]
      literals = [bearer, *held].map(&:to_s).reject(&:empty?)
      return true if texts.any? { |text| literals.any? { |literal| text.include?(literal) } }

      user_token_in?(texts, public_key)
    end

    # Every hash key and string value, at any depth. JSON.generate escapes a
    # quote or backslash again, so a credential holding one is only found here.
    def decoded_strings(value)
      case value
      when Hash then value.flat_map { |key, element| [key.to_s, *decoded_strings(element)] }
      when Array then value.flat_map { |element| decoded_strings(element) }
      when String then [value]
      else []
      end
    end

    def user_token_in?(texts, public_key)
      signature_length = signature_length(public_key)
      return false unless signature_length

      candidates = texts.each_with_object(Set.new) do |text, found|
        found.merge(token_candidates(text, signature_length))
      end
      candidates.any? { |candidate| verifies?(candidate, public_key) }
    end

    # A token can sit inside a longer string with other base64url text glued
    # to either end ("x" + token + "y"), so each dotted run is cut into every
    # window of three segments. The header is tried from each "eyJ" in its
    # segment, and the signature is cut to the length an RS256 signature with
    # this key has, so text appended after the token cannot hide it.
    def token_candidates(text, signature_length)
      text.scan(DOTTED_SEGMENTS).flat_map do |run|
        run.split(".").each_cons(JWT_SEGMENT_COUNT).flat_map do |head, payload, tail|
          next [] if tail.length < signature_length

          signature = tail[0, signature_length]
          header_starts(head).map { |start| [head[start..], payload, signature].join(".") }
        end
      end
    end

    def header_starts(segment)
      starts = []
      index = segment.index(JWT_HEADER_START)
      while index
        starts << index
        index = segment.index(JWT_HEADER_START, index + 1)
      end
      starts
    end

    def verifies?(candidate, public_key)
      TokenVerifier.verify(candidate, public_key:)
      true
    rescue TokenVerifier::ExpiredToken
      true
    rescue TokenVerifier::InvalidToken
      false
    end

    # The unpadded base64url length of an RS256 signature: the modulus size in
    # bytes. With no readable key nothing verifies, as in Identity.resolve.
    def signature_length(public_key)
      rsa = public_key.is_a?(OpenSSL::PKey::RSA) ? public_key : OpenSSL::PKey::RSA.new(public_key.to_s)
      (rsa.n.num_bytes * 4 / 3.0).ceil
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    private_class_method :decoded_strings, :user_token_in?, :token_candidates, :header_starts, :verifies?,
      :signature_length
  end
end

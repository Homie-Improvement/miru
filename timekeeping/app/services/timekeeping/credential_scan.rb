# frozen_string_literal: true

module Timekeeping
  # Finds a credential in an entry write's body before anything is stored, so
  # no entry, audit row, receipt or outbox snapshot can carry one. It reads the
  # parsed body, never the raw request text: a JSON escape such as \u0065 hides
  # a token from the raw text, and parsing restores it in the stored value.
  #
  # Pure: the caller's bearer token, the held credentials and the public key
  # are arguments, and nothing is read from ENV.
  module CredentialScan
    # A run of base64 segments joined by dots. TokenVerifier accepts only three
    # base64url segments, its header starting with HEADER_START and at most
    # MAX_HEADER_LENGTH long, so this search covers every token it accepts.
    # Standard base64 characters and padding are also taken, because anyone
    # holding an issued token can respell its signature that way without the
    # signing key, and the spelling turns back into the live token.
    DOTTED_SEGMENTS = %r{[A-Za-z0-9_+/=-]+(?:\.[A-Za-z0-9_+/=-]+)+}
    JWT_HEADER_START = TokenVerifier::HEADER_START
    JWT_SEGMENT_COUNT = TokenVerifier::SEGMENT_COUNT
    MAX_HEADER_LENGTH = TokenVerifier::MAX_HEADER_LENGTH

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

    # Candidates are made and checked one at a time, so a body built to yield
    # many of them never holds them all in memory, and the search stops at the
    # first one that verifies.
    def user_token_in?(texts, public_key)
      rsa = rsa_key(public_key)
      return false unless rsa

      signature_length = signature_length(rsa)
      texts.lazy.flat_map { |text| token_candidates(text, signature_length) }
        .uniq.any? { |candidate| verifies?(candidate, rsa) }
    end

    # A token can sit inside a longer string with other base64url text glued
    # to either end ("x" + token + "y"), so each dotted run is cut into every
    # window of three segments. The header is tried from each "eyJ" near the
    # end of its segment. The signature is read back to base64url without
    # padding, then cut to the length an RS256 signature with this key has,
    # so neither a respelling nor text appended after the token can hide it.
    # The header and payload are signed as written, so they are left as they
    # are: any other spelling of them no longer verifies.
    def token_candidates(text, signature_length)
      text.scan(DOTTED_SEGMENTS).lazy.flat_map do |run|
        run.split(".").each_cons(JWT_SEGMENT_COUNT).lazy.flat_map do |head, payload, tail|
          signature = tail.tr("+/", "-_").delete("=")
          next [] if signature.length < signature_length

          signature = signature[0, signature_length]
          header_starts(head).lazy.map { |start| [head[start..], payload, signature].join(".") }
        end
      end
    end

    # Only the last MAX_HEADER_LENGTH characters of a segment can hold the
    # start of a token's header, because the header ends where the segment
    # does. Searching the whole segment would make a long run of "eyJ" cost
    # the square of its length.
    def header_starts(segment)
      starts = []
      index = segment.index(JWT_HEADER_START, [segment.length - MAX_HEADER_LENGTH, 0].max)
      while index
        starts << index
        index = segment.index(JWT_HEADER_START, index + 1)
      end
      starts
    end

    def verifies?(candidate, rsa)
      TokenVerifier.verify(candidate, public_key: rsa)
      true
    rescue TokenVerifier::ExpiredToken
      true
    rescue TokenVerifier::InvalidToken
      false
    end

    # With no readable key nothing verifies, as in Identity.resolve.
    def rsa_key(public_key)
      public_key.is_a?(OpenSSL::PKey::RSA) ? public_key : OpenSSL::PKey::RSA.new(public_key.to_s)
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    # The unpadded base64url length of an RS256 signature: the modulus size in
    # bytes.
    def signature_length(rsa)
      (rsa.n.num_bytes * 4 / 3.0).ceil
    end

    private_class_method :decoded_strings, :user_token_in?, :token_candidates, :header_starts, :verifies?,
      :rsa_key, :signature_length
  end
end

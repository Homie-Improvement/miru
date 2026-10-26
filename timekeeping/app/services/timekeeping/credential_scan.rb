# frozen_string_literal: true

module Timekeeping
  # Finds a credential in an entry write's body before anything is stored, so
  # no entry, audit row, receipt or outbox snapshot can carry one. It reads the
  # parsed body, never the raw request text: a JSON escape such as \u0065 hides
  # a token from the raw text, and parsing restores it in the stored value.
  #
  # Pure: the caller's bearer token, the held credentials, the public key and
  # the service secret are arguments, and nothing is read from ENV.
  module CredentialScan
    # A run of base64 segments joined by dots, in base64url or standard base64,
    # padded or not: a JWT verifier decodes a signature in any of them.
    DOTTED_SEGMENTS = %r{[A-Za-z0-9_+/=-]+(?:\.[A-Za-z0-9_+/=-]+)+}
    # A user token is a header, a payload and then its signature.
    SEGMENTS_BEFORE_SIGNATURE = 2
    SIGNATURE_DIGEST = "SHA256"
    # Every JSON token header opens with '{"', which base64 spells "eyJ".
    HEADER_START = "eyJ"
    # An HS256 signature is one SHA-256 digest: 32 bytes, 43 unpadded base64
    # characters.
    HMAC_SIGNATURE_LENGTH = 43

    module_function

    # True when the body holds, anywhere, the bearer token, a held credential,
    # a user token signed with the given key, or a service token signed with
    # the service secret.
    def found?(parsed_body, bearer:, held:, public_key:, service_secret:)
      texts = [JSON.generate(parsed_body), *decoded_strings(parsed_body)]
      literals = [bearer, *held].map(&:to_s).reject(&:empty?)
      return true if texts.any? { |text| literals.any? { |literal| text.include?(literal) } }

      rsa = rsa_key(public_key)
      return true if rsa.present? && texts.any? { |text| signed_token_in?(text, rsa) }

      secret = service_secret.to_s
      !secret.empty? && texts.any? { |text| service_token_in?(text, secret) }
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

    # A token is found by its signature alone: any dotted segment that follows
    # two others and opens with a valid RS256 signature made by the key. Only
    # the key's holder can make one, and the monolith signs nothing but user
    # tokens with it, so the token is found whatever its header or payload say,
    # however long they are and whatever text is glued around them, and an
    # expired token counts too. Each segment costs one RSA public-key
    # operation, so the work grows with the body's length, not its square.
    def signed_token_in?(text, rsa)
      text.scan(DOTTED_SEGMENTS).any? do |run|
        run.split(".").drop(SEGMENTS_BEFORE_SIGNATURE).any? { |segment| key_signature?(segment, rsa) }
      end
    end

    # The segment is cut to the length a signature with this key has, so text
    # appended after the token cannot hide it, and read in either base64
    # alphabet with or without padding, as a verifier would read it.
    def key_signature?(segment, rsa)
      length = encoded_signature_length(rsa)
      encoded = segment.tr("-_", "+/").delete("=")
      return false if encoded.length < length

      signature = pad(encoded[0, length]).unpack1("m")
      signature.bytesize == rsa.n.num_bytes && rsa.verify_recover(SIGNATURE_DIGEST, signature).present?
    rescue OpenSSL::PKey::PKeyError
      false
    end

    # A service token is found by its signature alone: a segment that follows
    # two others and opens with the HS256 signature, under the service secret,
    # of the two segments before it. No list of minted tokens is needed, so a
    # token minted for another request is found too, expired or not. Text
    # glued before the header is skipped by trying each "eyJ" start in the
    # header segment, within the header length the verifier accepts; text
    # glued after the signature is cut off.
    def service_token_in?(text, secret)
      text.scan(DOTTED_SEGMENTS).any? do |run|
        segments = run.split(".")
        (SEGMENTS_BEFORE_SIGNATURE...segments.length).any? do |index|
          signature = hmac_signature(segments[index])
          signature && header_starts(segments[index - 2]).any? do |header|
            ActiveSupport::SecurityUtils.secure_compare(
              OpenSSL::HMAC.digest(SIGNATURE_DIGEST, secret, "#{header}.#{segments[index - 1]}"), signature
            )
          end
        end
      end
    end

    # The first HMAC_SIGNATURE_LENGTH characters of the segment as signature
    # bytes, read in either base64 alphabet as a verifier would, or nil when
    # the segment is too short to hold one.
    def hmac_signature(segment)
      encoded = segment.tr("-_", "+/").delete("=")
      pad(encoded[0, HMAC_SIGNATURE_LENGTH]).unpack1("m") if encoded.length >= HMAC_SIGNATURE_LENGTH
    end

    def header_starts(segment)
      earliest = [segment.length - ServiceTokenVerifier::MAX_HEADER_LENGTH, 0].max
      (earliest...segment.length).filter_map do |start|
        segment[start..] if segment[start, HEADER_START.length] == HEADER_START
      end
    end

    def pad(encoded)
      encoded + ("=" * (-encoded.length % 4))
    end

    # With no readable key nothing verifies, as in Identity.resolve.
    def rsa_key(public_key)
      public_key.is_a?(OpenSSL::PKey::RSA) ? public_key : OpenSSL::PKey::RSA.new(public_key.to_s)
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    # The unpadded base64 length of an RS256 signature: the modulus size in
    # bytes.
    def encoded_signature_length(rsa)
      (rsa.n.num_bytes * 4 / 3.0).ceil
    end

    private_class_method :decoded_strings, :signed_token_in?, :key_signature?, :service_token_in?, :hmac_signature,
      :header_starts, :pad, :rsa_key, :encoded_signature_length
  end
end

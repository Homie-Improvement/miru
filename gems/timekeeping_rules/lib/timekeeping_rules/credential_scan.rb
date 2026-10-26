# frozen_string_literal: true

require "json"
require "openssl"

module TimekeepingRules
  # Finds a credential in an entry write's body before anything is stored, so
  # no entry, audit row, receipt or outbox snapshot can carry one. It reads the
  # parsed body, never the raw request text: a JSON escape such as \u0065 hides
  # a token from the raw text, and parsing restores it in the stored value.
  #
  # Pure: the caller's bearer token, the held credentials and the public key
  # are arguments, and nothing is read from ENV. The Timekeeping service passes
  # bearer: and held:, the monolith's local owner passes held_token:; a nil or
  # empty credential is not held, so it never matches a body.
  module CredentialScan
    # A run of base64 segments joined by dots, in base64url or standard base64,
    # padded or not: a JWT verifier decodes a signature in any of them.
    DOTTED_SEGMENTS = %r{[A-Za-z0-9_+/=-]+(?:\.[A-Za-z0-9_+/=-]+)+}
    # A signed token is a header, a payload and then its signature.
    SEGMENTS_BEFORE_SIGNATURE = 2
    SIGNATURE_DIGEST = "SHA256"

    module_function

    # True when the body holds, anywhere, the bearer token, a held credential,
    # or a user or service token signed with the given key.
    def found?(parsed_body, public_key:, bearer: nil, held: [], held_token: nil)
      texts = [JSON.generate(parsed_body), *decoded_strings(parsed_body)]
      literals = [bearer, held_token, *held].map(&:to_s).reject(&:empty?)
      return true if texts.any? { |text| literals.any? { |literal| text.include?(literal) } }

      rsa = rsa_key(public_key)
      !rsa.nil? && texts.any? { |text| signed_token_in?(text, rsa) }
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
    # the key's holder can make one, and the monolith signs only user and
    # service tokens with it, so the token is found whatever its header or
    # payload say, however long they are and whatever text is glued around
    # them, and an expired token counts too. Each segment costs one RSA
    # public-key operation, so the work grows with the body's length, not its
    # square.
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
      return false unless signature.bytesize == rsa.n.num_bytes

      recovered = rsa.verify_recover(SIGNATURE_DIGEST, signature)
      !recovered.nil? && !recovered.empty?
    rescue OpenSSL::PKey::PKeyError
      false
    end

    def pad(encoded)
      encoded + ("=" * (-encoded.length % 4))
    end

    # With no readable key nothing verifies. A nil key reads as no key: an
    # empty PEM never parses.
    def rsa_key(public_key)
      return public_key if public_key.is_a?(OpenSSL::PKey::RSA)
      return nil if public_key.nil? || public_key.to_s.empty?

      OpenSSL::PKey::RSA.new(public_key.to_s)
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    # The unpadded base64 length of an RS256 signature: the modulus size in
    # bytes.
    def encoded_signature_length(rsa)
      (rsa.n.num_bytes * 4 / 3.0).ceil
    end

    private_class_method :decoded_strings, :signed_token_in?, :key_signature?, :pad, :rsa_key,
      :encoded_signature_length
  end
end

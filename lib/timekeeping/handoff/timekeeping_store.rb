# frozen_string_literal: true

require "net/http"

module Timekeeping
  module Handoff
    # The checkpoint store over Timekeeping's tables, reached through the
    # service's internal handoff routes. The two applications share no
    # database credential (docs/architecture/timekeeping-soa.md section 11),
    # so every read and write goes over HTTP with the service token.
    #
    # Every failure raises Store::Error, the same error MonolithStore raises,
    # carrying only the HTTP status, the answered reason or the exception
    # class: never the token or a row. It never retries. A load that timed out
    # may still have committed, and loading the same checkpoint again is safe.
    class TimekeepingStore
      include Store

      CHECKPOINT_PATH = "/internal/v1/handoff/checkpoint"
      ENTRY_ID_SEQUENCE_PATH = "/internal/v1/handoff/entry_id_sequence"
      OUTBOX_POSITION_PATH = "/internal/v1/handoff/outbox_position"
      CORRECTION_SNAPSHOTS_PATH = "/internal/v1/handoff/correction_snapshots"
      FENCE_PATH = "/internal/v1/handoff/admission/fence"
      ADMIT_PATH = "/internal/v1/handoff/admission/admit"
      SETTLE_PATH = "/internal/v1/handoff/settle"
      STOP_APPLYING_PATH = "/internal/v1/handoff/stop_applying"
      DRAIN_PATH = "/internal/v1/handoff/drain"

      # A refusal reason is copied into Store::Error only in the shape every
      # Timekeeping reason has, so an answer that echoes the bearer or any
      # other text never puts it into a message or a log.
      REASON_FORMAT = /\A[a-z_]{1,64}\z/

      # What Timekeeping answered to a settle request: whether its settle step
      # is open after the call, and how many invoice operations are still
      # prepared.
      SettleAnswer = Data.define(:settling, :prepared_operations)

      OPEN_TIMEOUT_SECONDS = 5
      # A whole checkpoint loads in one request, and a fence waits up to 60 s
      # for writes already admitted, so answers take far longer than an
      # ordinary entry read.
      READ_TIMEOUT_SECONDS = 300

      TRANSPORT_ERRORS = [
        SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError
      ].freeze

      def initialize(base_url: ENV[EntryApiClient::BASE_URL_ENV],
                     token: ENV[::Internal::V1::BaseController::SERVICE_TOKEN_ENV])
        @base_url = base_url.to_s
        @token = token.to_s
      end

      def export_checkpoint
        verified_checkpoint(request(:get, CHECKPOINT_PATH))
      end

      # Returns the checkpoint Timekeeping read back from its loaded tables,
      # after checking it matches the checkpoint sent.
      def load_checkpoint(checkpoint)
        loaded = verified_checkpoint(request(:put, CHECKPOINT_PATH, checkpoint.to_json))
        raise Store::Error, "Timekeeping loaded rows that do not match the checkpoint sent" unless loaded.digest == checkpoint.digest

        loaded
      end

      def highest_outbox_position
        integer_field(request(:get, OUTBOX_POSITION_PATH), "outbox_position")
      end

      # Returns the id the sequence hands out next.
      def advance_entry_id_sequence(above:)
        integer_field(request(:post, ENTRY_ID_SEQUENCE_PATH, JSON.generate("above" => Integer(above))), "next_id")
      end

      # Replaces the snapshots of each given entry at generation with one at
      # version. Returns the number written. Decimals in the snapshots' jsonb
      # fields go out as bare JSON numbers, so none is rounded or quoted.
      def write_correction_snapshots(snapshots:, version:, generation:)
        body = LosslessSql.json_text("snapshots" => snapshots, "version" => version, "generation" => generation)
        integer_field(request(:put, CORRECTION_SNAPSHOTS_PATH, body), "written")
      end

      # Timekeeping::Admission refuses every entry write that does not carry
      # the admitted generation, so its fence holds against Timekeeping's
      # writers.
      def enforces_fence?
        true
      end

      def fence_admission
        request(:post, FENCE_PATH, "{}")
        nil
      end

      def admit(generation:)
        request(:post, ADMIT_PATH, JSON.generate("generation" => generation))
        nil
      end

      def settle(generation:)
        body = request(:post, SETTLE_PATH, JSON.generate("generation" => generation))
        SettleAnswer.new(settling: boolean_field(body, "settling"),
                         prepared_operations: integer_field(body, "prepared_operations"))
      end

      def stop_applying(generation:)
        request(:post, STOP_APPLYING_PATH, JSON.generate("generation" => generation))
        nil
      end

      # Whether every outbox snapshot at or below through has been sent.
      def drain(through:)
        boolean_field(request(:post, DRAIN_PATH, JSON.generate("through" => through)), "drained")
      end

      private

        # Returns the body of a 200 answer.
        def request(method, path, body = nil)
          raise Store::Error, "#{EntryApiClient::BASE_URL_ENV} is not set" if @base_url.blank?
          raise Store::Error, "#{::Internal::V1::BaseController::SERVICE_TOKEN_ENV} is not set" if @token.blank?

          uri = URI.join(@base_url, path)
          # Net::HTTP re-sends a GET or PUT once after a read timeout by
          # default; max_retries: 0 keeps a slow load from being sent twice.
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                         open_timeout: OPEN_TIMEOUT_SECONDS,
                                                         read_timeout: READ_TIMEOUT_SECONDS,
                                                         max_retries: 0) do |http|
            http.request(build_request(method, uri, body))
          end
          refuse_answer!(method, path, response) unless response.is_a?(Net::HTTPOK)

          response.body
        rescue *TRANSPORT_ERRORS => error
          raise Store::Error, "Timekeeping #{method.upcase} #{path} failed: #{error.class}"
        end

        def build_request(method, uri, body)
          request = { get: Net::HTTP::Get, put: Net::HTTP::Put, post: Net::HTTP::Post }.fetch(method).new(uri)
          request["Authorization"] = "Bearer #{@token}"
          if body
            request["Content-Type"] = "application/json"
            request.body = body
          end
          request
        end

        # Names the reason Timekeeping answered with, when the body holds one
        # in REASON_FORMAT.
        def refuse_answer!(method, path, response)
          reason = begin
            JSON.parse(response.body.to_s)["reason"] if response.body.present?
          rescue JSON::ParserError, TypeError, NoMethodError
            nil
          end
          message = "Timekeeping #{method.upcase} #{path} answered #{response.code}"
          message += " #{reason}" if reason.is_a?(String) && reason.match?(REASON_FORMAT)
          raise Store::Error, message
        end

        def integer_field(body, key)
          value = answer_field(body, key)
          return value if value.is_a?(Integer)

          raise Store::Error, "Timekeeping answered without an integer #{key}"
        end

        # Only a JSON true or false: a quoted "true" or a 1 is refused, so a
        # garbled answer is never read as a yes.
        def boolean_field(body, key)
          value = answer_field(body, key)
          return value if [true, false].include?(value)

          raise Store::Error, "Timekeeping answered without a boolean #{key}"
        end

        # The key's value in a JSON object answer, or nil when the answer is
        # not an object.
        def answer_field(body, key)
          answer = JSON.parse(body)
          answer[key] if answer.is_a?(Hash)
        rescue JSON::ParserError => error
          raise Store::Error, "Timekeeping answered an unreadable body: #{error.class}"
        end

        # A reply cut short or changed on the way would no longer match its
        # own digest. Checkpoint.from_json reads whatever JSON it is given, so
        # a body of the wrong structure fails inside it with a Ruby error.
        def verified_checkpoint(body)
          checkpoint = begin
            Checkpoint.from_json(body)
          rescue JSON::ParserError, Checkpoint::ShapeError, KeyError, TypeError, NoMethodError, ArgumentError => error
            raise Store::Error, "Timekeeping answered an unreadable checkpoint: #{error.class}"
          end
          mismatches = Checkpoint.verify(checkpoint)
          return checkpoint if mismatches.empty?

          tables = mismatches.pluck(:table).uniq.join(", ")
          raise Store::Error, "Timekeeping returned a checkpoint that does not match its own digest: #{tables}"
        end
    end
  end
end

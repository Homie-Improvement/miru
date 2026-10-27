# frozen_string_literal: true

require "net/http"

module Timekeeping
  # Forwards one entry create, update or destroy, or one bulk move or bulk
  # delete, to the Timekeeping service's entry API
  # (contracts/timekeeping/entry_api.yml) while Timekeeping owns the entries. Every HTTP call for these routes lives here, so callers see the
  # answered entry Hash or one of the errors below, never a Net:: exception.
  #
  # The token is minted for the context's actor, never for the entry's target
  # user, so Timekeeping decides with the signed-in user's own role. Error
  # messages carry only the route and status or the exception class: the
  # answer body may describe other users' data and is never passed on.
  #
  # It never retries. A call whose answer was lost may still have committed in
  # Timekeeping; a resend under the same request id carries the same
  # Idempotency-Key, so Timekeeping replays its answer instead of writing twice.
  # A committed destroy hides its entry from the lookup before the write, so its
  # resend goes through replay_destroy_entry, which only ever reads the stored
  # answer.
  class EntryWriteClient
    ENTRIES_PATH = "/v1/companies/%<company_id>d/entries"
    ENTRY_PATH = "/v1/companies/%<company_id>d/entries/%<entry_id>d"
    BULK_MOVE_PATH = "/v1/companies/%<company_id>d/entries/bulk-move"
    BULK_DELETE_PATH = "/v1/companies/%<company_id>d/entries/bulk-delete"

    # Fixed namespace for the version 5 UUIDs used as Idempotency-Key values.
    IDEMPOTENCY_NAMESPACE = "6f1c2c1e-5d7a-4c55-9a0e-1b9e8f3d2a41"

    # The fields a web or mobile write may set, the same fields the entry
    # controller permits today. A web or mobile update sends only these:
    # source fields and user_id are left out so an edit never rewrites an
    # entry's recorded origin or moves it to another user.
    EDIT_FIELDS = %w[project_id duration work_date note bill_status].freeze

    # The entry's recorded origin. The CLI writes it on create and update, as
    # its controller always has; the agent writes it on create.
    SOURCE_FIELDS = %w[source source_metadata].freeze

    # What an agent create records about the agent and its run.
    AGENT_FIELDS = %w[agent_id proof_url proof_metadata external_run_id external_session_id].freeze

    # The fields each writer may forward, by WriteContext actor kind and
    # operation. Anything else a caller passes, such as user_id or
    # review_status, is never sent. A kind with no row (a service or an agent
    # destroy) forwards no entry write at all. An import never updates; its
    # create body comes from import_create_body, which adds the import's own
    # source to these fields.
    FORWARDED_FIELDS = {
      "user" => { create: EDIT_FIELDS, update: EDIT_FIELDS },
      "import" => { create: EDIT_FIELDS },
      "cli" => { create: EDIT_FIELDS + SOURCE_FIELDS, update: EDIT_FIELDS + SOURCE_FIELDS },
      "agent" => { create: EDIT_FIELDS + SOURCE_FIELDS + AGENT_FIELDS, update: EDIT_FIELDS }
    }.transform_values(&:freeze).freeze

    # The contract requires both source fields on create. A writer that does
    # not forward its own records a manual entry.
    CREATE_SOURCE = { "source" => "manual", "source_metadata" => {} }.freeze

    # Asks Timekeeping to answer a DELETE only from its stored receipt
    # (contracts/timekeeping/entry_api.yml headers.idempotency_replay).
    REPLAY_ONLY_HEADER = "Idempotency-Replay"
    REPLAY_ONLY_VALUE = "only"

    # Sent as If-Match on a replay-only DELETE. It is never a version, so a
    # Timekeeping instance that predates the replay header refuses the delete
    # as version_conflict instead of discarding an entry the lookup hid.
    REPLAY_ONLY_IF_MATCH = "replay-only"

    # Timekeeping could not be reached, refused the monolith's own token, or
    # answered something unexpected. A subclass of the read client's error, so
    # it renders as the same retryable 503.
    class Error < EntryApiClient::Error; end

    # Timekeeping refused the actor, or the actor cannot be given a token for
    # the company. Rendered as 403.
    class Forbidden < StandardError; end

    # The entry changed after it was looked up (If-Match no longer matches).
    # Nothing was written. Rendered as 409 version_conflict.
    class Conflict < StandardError; end

    # Timekeeping refused the write as malformed, such as credential_in_body or
    # a reused Idempotency-Key with a different body. Rendered as 422.
    class Rejected < StandardError; end

    # Errors raised by a 409 answer, by its reason. Any other 409 reason is a
    # conflict too.
    CONFLICT_ERRORS = { "stale_generation" => Gateway::StaleGeneration }.freeze

    # Errors raised by every other non-2xx status. Any other 4xx is a
    # rejection, and anything else is an unavailable service.
    STATUS_ERRORS = { 401 => Error, 403 => Forbidden }.freeze

    def initialize(base_url: ENV[EntryApiClient::BASE_URL_ENV])
      @base_url = base_url.to_s
    end

    # Pure: the same request id, operation and entry id always give the same
    # key, and any difference gives a different key. A create has no entry id
    # yet and is keyed as "new".
    def self.idempotency_key(request_id:, operation:, entry_id: nil)
      Digest::UUID.uuid_v5(IDEMPOTENCY_NAMESPACE, "#{request_id}/#{operation}/#{entry_id || "new"}")
    end

    # Pure: the key of one bulk call, derived from the request id, the
    # operation and the set of entry ids, whatever their order. A resend that
    # names the same entries replays Timekeeping's stored answer. A resend
    # that names fewer, because some were already deleted, gets a new key and
    # writes the rest, instead of being refused as a reused key with a
    # different body.
    def self.bulk_idempotency_key(request_id:, operation:, entry_ids:)
      idempotency_key(request_id:, operation:, entry_id: entry_ids.map(&:to_i).sort.join(","))
    end

    # The create body for the writer of actor_kind. user and project are
    # records the caller already resolved inside the company, never raw
    # params.
    #
    # Timekeeping fingerprints the body as serialized, key order included, so
    # a retry must send its keys in the order the first attempt did. The
    # default source keys therefore come last, as they always have, and a
    # writer's own source values keep their place and win.
    def self.create_body(user:, project:, attributes:, actor_kind: "user")
      forwarded_fields(attributes, actor_kind:, operation: :create)
        .merge("project_id" => project.id, "user_id" => user.id)
        .merge(CREATE_SOURCE.deep_dup) { |_key, given, _default| given }
    end

    # The create body for an imported entry. Unlike create_body, it records
    # the import's own source ("source" and "source_metadata" of source), so
    # the entry keeps its origin, and bill_status is sent as given, billed
    # included, because an import writes each row's final status at once.
    def self.import_create_body(user:, project:, attributes:, source:)
      edit_fields(attributes)
        .merge("project_id" => project.id, "user_id" => user.id)
        .merge(source.to_h.deep_stringify_keys.slice("source", "source_metadata"))
    end

    # The EDIT_FIELDS of attributes, as sent.
    def self.edit_fields(attributes)
      forwarded_fields(attributes, actor_kind: "user", operation: :update)
    end

    # The fields of attributes the writer may forward for operation, as sent.
    # A form post carries every value as a string, and Timekeeping takes
    # duration only as a JSON number, so a numeric string is sent as the Float
    # the duration column would store. Any other duration is sent unchanged,
    # and Timekeeping refuses it.
    def self.forwarded_fields(attributes, actor_kind:, operation:)
      fields = attributes.to_h.stringify_keys.slice(*FORWARDED_FIELDS.fetch(actor_kind.to_s).fetch(operation))
      duration = fields["duration"]
      number = Float(duration, exception: false) if duration.is_a?(String)
      number.nil? ? fields : fields.merge("duration" => number)
    end

    # Returns the created entry Hash. idempotency_key replaces the key derived
    # from the request id, for a caller whose retries run under a new request
    # id, such as an import rerun, and must still be recognised as the same
    # create.
    def create_entry(context:, generation:, body:, idempotency_key: nil)
      path = format(ENTRIES_PATH, company_id: context.company.id)
      forward(Net::HTTP::Post, path, operation: "create", context:, generation:, body:,
                                     idempotency_key: idempotency_key || request_key(context, "create"))
    end

    # Returns the updated entry Hash. Only the fields the context's writer may
    # forward on update are sent.
    def update_entry(context:, generation:, entry_id:, version:, body:)
      path = format(ENTRY_PATH, company_id: context.company.id, entry_id:)
      fields = self.class.forwarded_fields(body, actor_kind: context.actor_kind, operation: :update)
      forward(Net::HTTP::Patch, path, operation: "update", context:, generation:, version:,
                                      idempotency_key: request_key(context, "update", entry_id), body: fields)
    end

    # Returns the discarded entry Hash.
    def destroy_entry(context:, generation:, entry_id:, version:)
      path = format(ENTRY_PATH, company_id: context.company.id, entry_id:)
      forward(Net::HTTP::Delete, path, operation: "destroy", context:, generation:, version:,
                                       idempotency_key: request_key(context, "destroy", entry_id))
    end

    # Moves the entries to the project in one call and returns Timekeeping's
    # answer, whose "results" list each entry id as "moved" or "not_found".
    # entry_ids are ids the caller already resolved inside the company, never
    # raw params. A stale generation refuses the whole call.
    def bulk_move(context:, generation:, entry_ids:, project_id:)
      path = format(BULK_MOVE_PATH, company_id: context.company.id)
      forward(Net::HTTP::Post, path, operation: "bulk_move", context:, generation:,
                                     idempotency_key: bulk_key(context, "bulk_move", entry_ids),
                                     body: { "entry_ids" => entry_ids, "project_id" => project_id })
    end

    # Discards the entries in one call and returns Timekeeping's answer, whose
    # "results" list each entry id as "deleted" or "not_found". The same
    # rules as bulk_move apply to entry_ids and to a stale generation.
    def bulk_delete(context:, generation:, entry_ids:)
      path = format(BULK_DELETE_PATH, company_id: context.company.id)
      forward(Net::HTTP::Post, path, operation: "bulk_delete", context:, generation:,
                                     idempotency_key: bulk_key(context, "bulk_delete", entry_ids),
                                     body: { "entry_ids" => entry_ids })
    end

    # Returns the stored answer of a destroy this request id already committed.
    # Timekeeping never deletes on this call: with no stored answer for the
    # same company, actor and key it answers 404, raised as RecordNotFound.
    def replay_destroy_entry(context:, generation:, entry_id:)
      path = format(ENTRY_PATH, company_id: context.company.id, entry_id:)
      forward(Net::HTTP::Delete, path, operation: "destroy", context:, generation:,
                                       idempotency_key: request_key(context, "destroy", entry_id),
                                       version: REPLAY_ONLY_IF_MATCH, replay_only: true)
    end

    private

      def request_key(context, operation, entry_id = nil)
        self.class.idempotency_key(request_id: context.request_id, operation:, entry_id:)
      end

      def bulk_key(context, operation, entry_ids)
        self.class.bulk_idempotency_key(request_id: context.request_id, operation:, entry_ids:)
      end

      def forward(request_class, path, operation:, context:, generation:, idempotency_key:, version: nil, body: nil,
                  replay_only: false)
        raise Error, "#{EntryApiClient::BASE_URL_ENV} is not set" if @base_url.blank?

        request = request_class.new(URI.join(@base_url, path))
        request["Authorization"] = "Bearer #{token_for(context, body)}"
        request["Ownership-Generation"] = generation.to_s
        request["Idempotency-Key"] = idempotency_key
        request["X-Request-Id"] = context.request_id.to_s
        request["If-Match"] = version.to_s unless version.nil?
        request[REPLAY_ONLY_HEADER] = REPLAY_ONLY_VALUE if replay_only
        unless body.nil?
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end

        response = send_request(request)
        raise refusal_for(operation, response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::ProtocolError,
             JSON::ParserError => error
        raise Error, "Timekeeping entry #{operation} failed: #{error.class}"
      end

      # The token carries project facts only for the project the body names.
      def token_for(context, body)
        project_ids = [body&.dig("project_id")].compact
        UserToken.mint(user: context.actor, company: context.company, project_ids:, agent: context.agent)
      rescue UserToken::NotInCompanyError, UserToken::AgentMismatchError => error
        raise Forbidden, "Timekeeping entry token refused: #{error.class}"
      rescue UserToken::MissingKeyError => error
        raise Error, "Timekeeping entry token unavailable: #{error.class}"
      end

      def refusal_for(operation, response)
        status = response.code.to_i
        message = "Timekeeping entry #{operation} answered #{status}"
        return ActiveRecord::RecordNotFound.new("Couldn't find TimesheetEntry", "TimesheetEntry") if status == 404
        return CONFLICT_ERRORS.fetch(reason_of(response), Conflict).new if status == 409

        error_class = STATUS_ERRORS.fetch(status) { (400..499).cover?(status) ? Rejected : Error }
        error_class.new(message)
      end

      # The contract's error bodies carry only a reason. Anything unreadable
      # counts as no reason.
      def reason_of(response)
        parsed = JSON.parse(response.body.to_s)
        parsed["reason"] if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def send_request(request)
        uri = request.uri
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: EntryApiClient::TIMEOUT_SECONDS,
                                            read_timeout: EntryApiClient::TIMEOUT_SECONDS) do |http|
          http.request(request)
        end
      end
  end
end

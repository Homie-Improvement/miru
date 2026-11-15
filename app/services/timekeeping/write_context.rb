# frozen_string_literal: true

module Timekeeping
  # Who is writing entries, for which company, under which request. The
  # gateway reads identity only from here, never from Current, so a write
  # started outside a web request (a job, the CLI, an agent) names its actor
  # explicitly and cannot pick up whoever Current happens to hold.
  #
  # actor is the user the write acts for, and the user a forwarded write's
  # token is minted for. agent is set only when an agent acts for that user.
  # An agent_destroy write detaches a deleted agent's entries; its actor is
  # the agent's backing user, and a forwarded detach uses a service token.
  #
  # idempotency_key and if_match are the request's own Idempotency-Key and
  # If-Match headers, nil when the request sent none, so a client's retry
  # and its expected version reach the store that owns the entries.
  class WriteContext < Data.define(:company, :actor, :actor_kind, :request_id, :agent, :idempotency_key, :if_match)
    ACTOR_KINDS = %w[user cli agent service import agent_destroy].freeze

    IDEMPOTENCY_KEY_HEADER = "Idempotency-Key"
    IF_MATCH_HEADER = "If-Match"

    # The context of a write made for a web request: its request id and the
    # two headers, read here so every controller reads them alike. A blank
    # header counts as absent.
    def self.for_request(request, company:, actor:, actor_kind:, agent: nil)
      new(
        company:, actor:, actor_kind:, agent:,
        request_id: request.request_id,
        idempotency_key: request.headers[IDEMPOTENCY_KEY_HEADER].presence,
        if_match: request.headers[IF_MATCH_HEADER].presence
      )
    end

    # :reek:LongParameterList
    def initialize(company:, actor:, actor_kind:, request_id:, agent: nil, idempotency_key: nil, if_match: nil)
      actor_kind = actor_kind.to_s
      raise ArgumentError, "unknown actor_kind #{actor_kind.inspect}" unless ACTOR_KINDS.include?(actor_kind)

      super
    end
  end
end

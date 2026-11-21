# frozen_string_literal: true

module Timekeeping
  # The one monolith module allowed to write entry state
  # (docs/architecture/timekeeping-soa.md sections 3.1 and 10.1).
  #
  # Each write runs in one transaction that first reads the single ownership
  # row FOR SHARE. A handoff updates that row, so it waits for every write
  # already admitted, and every write that starts after it sees the new state
  # and is refused. The row is global, so a handoff pauses every company's
  # entry writes at once. The ownership row is always locked before any entry
  # row, so the gateway and a handoff never wait on each other in opposite
  # orders.
  #
  # The store that owns the entries decides where the write goes, read from
  # Timekeeping::EntryOwner rather than from the generation: an aborted
  # handoff leaves the legacy store at a raised generation.
  #
  # Identity comes only from the Timekeeping::WriteContext, never from
  # Current, so a write started outside a web request names its actor.
  class Gateway
    # Raised when an entry write is refused because ownership is moving, or
    # cannot be read. Retryable: the write succeeds once the handoff ends. A
    # subclass of the billing refusal, so every place that already renders or
    # re-raises that refusal as 503 ownership_moving handles this one too.
    class OwnershipMoving < BillingFence::OwnershipMoving; end

    # Raised when the caller expected a different ownership generation than
    # the one the write saw. Rendered as 409 stale_generation.
    class StaleGeneration < StandardError
      def initialize(message = "stale_generation")
        super
      end
    end

    # What a bulk move or delete did. entries are the requested entries found
    # inside the scope, in request order. refusal is what the caller's check
    # answered; when it is set nothing was written. written is true once at
    # least one entry was written (legacy) or reported changed (the local
    # owner or Timekeeping).
    BulkResult = Data.define(:entries, :refusal, :written)

    # Casts requested ids the way the legacy where(id:) query did, so an id
    # that is not a number is dropped like a missing one instead of reaching
    # a path format that would raise.
    ENTRY_ID_TYPE = ActiveModel::Type::Integer.new

    # The per-entry answers of contracts/timekeeping/entry_api.yml bulk routes.
    MOVED_RESULT = "moved"
    DELETED_RESULT = "deleted"
    BULK_RESULTS = { bulk_move: MOVED_RESULT, bulk_delete: DELETED_RESULT }.freeze

    # Reads the ownership row under a share lock, or nil when it is missing.
    # Never TimekeepingOwnership.current, whose RecordNotFound would answer a
    # write with 404 instead of refusing it.
    module LockedOwnership
      def self.call
        TimekeepingOwnership.lock("FOR SHARE").find_by(id: TimekeepingOwnership::SINGLETON_ID)
      end
    end

    REFUSAL_REASONS = { OwnershipMoving => "ownership_moving", StaleGeneration => "stale_generation" }.freeze

    # Names the legacy create receipt lock, so it never shares a lock with
    # the prepared store's receipts for the same company, actor and key.
    LEGACY_CREATE_LOCK = "legacy_create"
    KEY_REUSED_REASON = "idempotency_key_reused"

    # Fixed namespace for the version 5 UUIDs used as detach operation ids.
    DETACH_OPERATION_NAMESPACE = "3d0f7a52-8c1e-4b6a-9f2d-5e7c1a9b4d60"

    attr_reader :context, :local_owner, :write_client, :read_client, :service_client, :ownership_reader

    # local_owner takes Timekeeping::LocalOwner.call's keywords and answers its
    # Outcome; it writes the prepared monolith's store.
    # :reek:LongParameterList
    def initialize(context:, local_owner: LocalOwner, write_client: EntryWriteClient.new,
                   read_client: EntryApiClient.new, service_client: ServiceCommandClient.new,
                   ownership_reader: LockedOwnership)
      @context = context
      @local_owner = local_owner
      @write_client = write_client
      @read_client = read_client
      @service_client = service_client
      @ownership_reader = ownership_reader
    end

    # Pure: the operation id of one detach attempt. The context's request_id
    # is new for every destroy attempt, so a later attempt makes Timekeeping
    # select the agent's entries again instead of replaying an earlier
    # receipt, which would skip entries that named the agent after an earlier
    # attempt rolled back. A resend within one attempt keeps the same id.
    def self.detach_operation_id(request_id:, agent_id:)
      Digest::UUID.uuid_v5(DETACH_OPERATION_NAMESPACE, "#{request_id}/detach_entries/#{agent_id}")
    end

    # The generation a writer that makes many writes reads once, before its
    # first write, and passes to each of them. A missing ownership row is
    # refused the way a write is refused.
    def self.current_generation
      ownership = TimekeepingOwnership.find_by(id: TimekeepingOwnership::SINGLETON_ID)
      raise OwnershipMoving if ownership.nil?

      ownership.generation
    end

    # Pure: the requested ids as Integers, without duplicates or ids that are
    # not numbers.
    def self.requested_entry_ids(entry_ids)
      Array(entry_ids).filter_map { |entry_id| ENTRY_ID_TYPE.cast(entry_id) }.uniq
    end

    # Pure: whether a bulk answer reports every one of entry_ids with result.
    # An id missing from the answer, or reported with any other result, makes
    # it false.
    def self.all_reported?(answer, entry_ids:, result:)
      reported_ids = Array(answer["results"]).filter_map do |entry_result|
        ENTRY_ID_TYPE.cast(entry_result["entry_id"]) if entry_result["result"] == result
      end
      entry_ids.all? { |entry_id| reported_ids.include?(entry_id) }
    end

    # Clears agent_id on every entry that names the agent, in the store that
    # owns the entries. The agent row is locked after the ownership row and
    # before the detach, so a concurrent entry save that names the agent
    # either finishes first, and is detached too, or waits and then fails its
    # agent existence check. Returns the number of entries detached.
    def detach_agent_entries(agent:)
      perform(nil) do |ownership, owner|
        agent.lock!
        case owner
        when :legacy
          agent.timesheet_entries.update_all(agent_id: nil)
        when :prepared
          local_detach(ownership:, agent:)
        when :timekeeping
          service_client.detach_agent_entries(
            company_id: agent.company_id, agent_id: agent.id, generation: ownership.generation,
            operation_id: self.class.detach_operation_id(request_id: context.request_id, agent_id: agent.id),
            request_id: context.request_id
          )
        end
      end
    end

    # project is a record the caller already resolved inside the context's
    # company. The target user is given one of two ways: user, a record the
    # caller already resolved, or requested_user_id, the request's own value,
    # with a block that resolves it by the caller's rule. The prepared store's
    # local owner decides a requested_user_id itself, so it receives the value
    # unchanged and the block is not called; the legacy store and Timekeeping
    # write for the user the block resolves. Returns the created
    # TimesheetEntry: saved on the legacy branch, unsaved when another store
    # owns the entries. A legacy retry with the client's own key returns a
    # read-only copy of the entry the first attempt committed.
    # :reek:LongParameterList
    def create(project:, attributes:, user: nil, requested_user_id: nil, expected_generation: nil, &resolve_user)
      perform(expected_generation) do |ownership, owner|
        case owner
        when :legacy
          legacy_create(project:, attributes:, user:, requested_user_id:, resolve_user:)
        when :prepared
          local_create(ownership:, project:, attributes:, user:, requested_user_id:)
        when :timekeeping
          forward_create(ownership:, project:, attributes:, user:, requested_user_id:, resolve_user:)
        end
      end
    end

    # Writes one imported row with its final bill status in a single gateway
    # call, so no refusal can leave a billed row stored as unbilled. Unlike
    # create, a billed status is allowed here: create takes bill_status from a
    # web or mobile form, where billed must stay refused. attributes carry the
    # import's source and source_metadata. idempotency_key is sent on a
    # forwarded create in place of the request-id key, so a rerun of the same
    # row is replayed rather than written twice.
    def import(user:, project:, attributes:, idempotency_key:, expected_generation: nil)
      final = attributes.to_h.stringify_keys

      perform(expected_generation) do |ownership, owner|
        case owner
        when :legacy
          import_legacy(user:, project:, final:)
        when :prepared
          identity = create_identity(user_id: user.id, project:, fields: final)
          row = replay_local(ownership:, operation: :create, identity:, keys: [idempotency_key].compact) ||
                local_write(ownership:, operation: :create, body: import_body(user:, project:, final:), identity:,
                            idempotency_key:)
          hydrate(row, user_id: user.id)
        when :timekeeping
          import_forwarded(ownership:, user:, project:, final:, idempotency_key:)
        end
      end
    end

    # authorize is called with the entry found in the owning store, inside the
    # transaction and before the write, so the policy decides on the copy the
    # write will change.
    #
    # In the prepared store, a retry of an update this actor already committed
    # replays the stored answer before the edit policy runs: the first update
    # may have made the entry one that policy refuses to edit, such as billed.
    # The replayed entry passes the lookup's company, id and scope checks and
    # then authorize_replay, the permission to read back a committed answer.
    # It defaults to authorize for callers that grant no separate one. After a
    # re-cutover, a receipt the prepared store kept is replayed the same way
    # (see replay_prepared_receipt).
    # :reek:LongParameterList
    def update(entry_id:, project:, attributes:, authorize:, authorize_replay: authorize, expected_generation: nil,
               scope: :company)
      perform(expected_generation) do |ownership, owner|
        identity = update_identity(project:, attributes:)
        replayed = replay_committed(ownership:, owner:, operation: :update, entry_id:, identity:)
        next replayed_update(replayed, entry_id:, authorize_replay:, scope:) if replayed

        found = find_authorized(ownership:, entry_id:, authorize:, scope:)
        entry = found.entry
        case owner
        when :legacy
          entry.project = project
          entry.update!(attributes)
          entry
        when :prepared
          local_update(ownership:, found:, project:, attributes:, identity:)
        when :timekeeping
          body = normalized_update_attributes(entry, attributes).merge("project_id" => project.id)
          row = write_client.update_entry(context:, generation: ownership.generation, entry_id: entry.id,
                                          version: found.version, body:)
          hydrate(row, user_id: entry.user_id)
        end
      end
    end

    # Returns true once the owning store has discarded the entry. A forwarded
    # destroy that Timekeeping answered with success is a success, whatever
    # the answer holds: the entry is already gone there.
    #
    # Timekeeping's lookup no longer finds an entry this actor already
    # deleted, so when the answer to that delete was lost, its retry would
    # otherwise end at the lookup. A lookup that finds nothing is therefore
    # followed by a DELETE that Timekeeping answers only from its stored
    # receipt for the same actor and key (see replay_timekeeping_destroy).
    # An entry the lookup finds but the scope refuses is still live, so no
    # delete of it can have committed, and it is refused without a replay.
    #
    # In the prepared store, a retry with the request's own Idempotency-Key
    # replays this actor's stored answer before the lookup, which no longer
    # finds the discarded entry. After a re-cutover, a receipt the prepared
    # store kept is replayed the same way.
    def destroy(entry_id:, authorize:, expected_generation: nil, scope: :company)
      perform(expected_generation) do |ownership, owner|
        replayed = replay_committed(ownership:, owner:, operation: :destroy, entry_id:, identity: {})
        if replayed
          authorize.call(EntryLookup.replayed(context:, row: replayed, entry_id:, scope:))
          next true
        end

        found = begin
          EntryLookup.find_in_owner(ownership:, context:, entry_id:, read_client:)
        rescue ActiveRecord::RecordNotFound
          next replay_timekeeping_destroy(ownership:, entry_id:, authorize:, scope:) if owner == :timekeeping
          next replay_local_destroy(ownership:, entry_id:, authorize:, scope:) if owner == :prepared

          raise
        end
        entry = found.entry
        EntryLookup.check_target(entry, context:, entry_id:, scope:)
        authorize.call(entry)
        case owner
        when :legacy
          entry.discard!
        when :prepared
          local_write(ownership:, operation: :destroy, entry_id: entry.id, if_match: context.if_match || found.version,
                      body: {}, identity: {}, idempotency_key: request_key(:destroy, entry.id))
        when :timekeeping
          write_client.destroy_entry(context:, generation: ownership.generation, entry_id: entry.id,
                                     version: found.version)
        end
        true
      end
    end

    # Moves the requested entries to project, a record the caller already
    # resolved inside the context's company. Ids that are missing, not
    # numbers, or outside the scope are dropped silently. check is called with
    # the found entries before any write; a non-nil answer is returned as the
    # refusal and nothing is written.
    #
    # An entry that fails the legacy model's update validations, such as a
    # locked entry an employee moves, is skipped silently on both branches.
    # A generation or handoff refusal raises and leaves no entry moved.
    def bulk_move(entry_ids:, project:, check:, expected_generation:, scope: :company)
      identity = bulk_identity(entry_ids).merge("project_id" => project.id)
      bulk_write(operation: :bulk_move, identity:, entry_ids:, check:, expected_generation:,
                 scope:) do |ownership, owner, entries|
        case owner
        when :legacy
          write_each_admitted(entries, owner:, expected_generation:) { |entry| entry.update(project_id: project.id) }
        when :prepared
          local_bulk_move(ownership:, entries:, project:, identity:)
        when :timekeeping
          forward_bulk_move(ownership:, entries:, project:)
        end
      end
    end

    # Discards the requested entries, under the same id, scope, check and
    # refusal rules as bulk_move. Discarding runs no validations, as the
    # legacy discard_all never did.
    def bulk_delete(entry_ids:, check:, expected_generation:, scope: :company)
      identity = bulk_identity(entry_ids)
      bulk_write(operation: :bulk_delete, identity:, entry_ids:, check:, expected_generation:,
                 scope:) do |ownership, owner, entries|
        case owner
        when :legacy
          write_each_admitted(entries, owner:, expected_generation:, &:discard)
        when :prepared
          local_bulk_delete(ownership:, entries:, identity:)
        when :timekeeping
          forward_bulk_delete(ownership:, entries:, entry_ids:)
        end
      end
    end

    private

      # One gateway transaction for the whole request, so a refusal at any
      # entry rolls back every write before it and is counted once. The block
      # answers whether anything was written.
      #
      # In the prepared store, a retry with the request's own Idempotency-Key
      # replays this actor's stored answer before the lookup and the check,
      # since the first write may have discarded or moved the entries. After a
      # re-cutover, a receipt the prepared store kept is replayed the same way.
      # A replayed answer is returned with the entries the lookup finds now,
      # as a first answer is.
      # :reek:LongParameterList
      def bulk_write(operation:, identity:, entry_ids:, check:, expected_generation:, scope:)
        perform(expected_generation) do |ownership, owner|
          replayed = replay_committed(ownership:, owner:, operation:, identity:,
                                      keys: replay_keys(local_bulk_key(operation, identity)))
          replayed ||= replay_carried_bulk(ownership:, operation:, identity:) if owner == :prepared
          entries = bulk_entries(ownership:, entry_ids:, scope:)
          if replayed
            next BulkResult.new(entries:, refusal: nil, written: reported?(replayed, BULK_RESULTS.fetch(operation)))
          end

          refusal = check.call(entries)
          next BulkResult.new(entries:, refusal:, written: false) unless refusal.nil?

          BulkResult.new(entries:, refusal: nil, written: yield(ownership, owner, entries))
        end
      end

      # Only a not-found answer drops an id, so a foreign id looks exactly like
      # a missing one. Every other error, such as Timekeeping being
      # unreachable, still fails the request.
      def bulk_entries(ownership:, entry_ids:, scope:)
        self.class.requested_entry_ids(entry_ids).filter_map do |entry_id|
          EntryLookup.find(ownership:, context:, entry_id:, read_client:, scope:).entry
        rescue ActiveRecord::RecordNotFound
          nil
        end
      end

      # Reads ownership again before every entry write, so a generation change
      # or handoff that lands between two writes refuses the rest of the
      # request, and the refusal rolls back the writes already made. Each write
      # is the same non-raising call the relation-wide update and discard_all
      # made per record, so a failing entry is skipped, not raised. Answers
      # true when any entry was attempted, as discard_all.any? did.
      #
      # Each written row stays locked until the transaction ends, so entries
      # are written in id order: two requests naming the same entries in
      # opposite orders would otherwise wait on each other and deadlock.
      def write_each_admitted(entries, owner:, expected_generation:)
        entries.sort_by(&:id).each do |entry|
          raise OwnershipMoving unless EntryOwner.for(admitted_ownership(expected_generation)) == owner

          yield entry
        end
        entries.any?
      end

      # Timekeeping's bulk rules do not run every legacy update validation (a
      # non-billable target project, for one), so entries the legacy save
      # would skip are left out of the call and skipped the same way. Every
      # found entry keeps the target project in memory, as the legacy entries
      # do after a skipped save, so both branches render the same rows. The
      # call is sent even when every entry is skipped, so Timekeeping still
      # refuses a stale generation instead of the request answering 200.
      def forward_bulk_move(ownership:, entries:, project:)
        answer = write_client.bulk_move(context:, generation: ownership.generation,
                                        entry_ids: movable_entry_ids(entries, project), project_id: project.id)
        reported?(answer, MOVED_RESULT)
      end

      def forward_bulk_delete(ownership:, entries:, entry_ids:)
        return replay_timekeeping_bulk_delete(entry_ids) if entries.empty?

        answer = write_client.bulk_delete(context:, generation: ownership.generation, entry_ids: entries.map(&:id))
        reported?(answer, DELETED_RESULT)
      end

      # The lookup hides every entry a committed delete discarded, so a retry
      # whose first attempt deleted all the requested entries finds none. Only
      # the client's own Idempotency-Key survives a resend, so only then is
      # Timekeeping asked for that attempt's stored answer; it never deletes
      # on this call. The answer counts as written only when it reports every
      # requested id deleted. A first attempt that named an id it did not find
      # was keyed over fewer ids, so it has no receipt here and stays unwritten.
      # A miss (no receipt, or an older Timekeeping refusing the replay's fixed
      # generation) is rescued here, before perform would count it
      # as a refused write.
      def replay_timekeeping_bulk_delete(entry_ids)
        requested = self.class.requested_entry_ids(entry_ids)
        return false if context.idempotency_key.nil? || requested.empty?

        answer = write_client.replay_bulk_delete(context:, entry_ids: requested)
        self.class.all_reported?(answer, entry_ids: requested, result: DELETED_RESULT)
      rescue ActiveRecord::RecordNotFound, StaleGeneration, EntryWriteClient::Conflict
        false
      end

      # Skips the same entries as forward_bulk_move. With nothing to write no
      # call is made: the gateway has already fenced the generation, and the
      # local owner would store a receipt for an empty write.
      # A create for a resolved user sends that user's id. A create for a
      # requested user sends the request's value unchanged, and the local
      # owner decides it by the shared target-user rule; the draft the legacy
      # create rules check is then built for the acting user, since no target
      # record was resolved. The answer is hydrated for the user the owner
      # wrote the entry for.
      #
      # A retry of a create the legacy store committed is matched to its
      # legacy receipt first, as in forward_create, and answered from the row
      # the rollback carried into this store.
      # :reek:LongParameterList
      def local_create(ownership:, project:, attributes:, user:, requested_user_id:)
        target_user_id = user ? user.id : requested_user_id
        receipt = carried_legacy_create(project:, attributes:, user_id: target_user_id)
        return local_carried_create(ownership:, receipt:) if receipt

        draft_user = user || context.actor
        identity = request_create_identity(project:, attributes:, user_id: target_user_id)
        row = replay_local(ownership:, operation: :create, identity:) || local_write(
          ownership:, operation: :create, identity:, idempotency_key: request_key(:create),
          body: create_body(user: draft_user, project:, attributes:).merge("user_id" => target_user_id)
        )
        hydrate(row, user_id: row["user_id"])
      end

      # The carried row is stored under the carried key with the fingerprint
      # of the forwarded body, so the replay sends that body with no identity.
      # The legacy receipt proves the create committed, so when the carried
      # row is missing the retry is refused rather than written again.
      def local_carried_create(ownership:, receipt:)
        carried_key = LegacyCreateReplay.carried_key(actor_kind: receipt.actor_kind, key: receipt.key)
        row = replay_local(ownership:, operation: :create, identity: nil, body: JSON.parse(receipt.forwarded_body),
                           keys: [carried_key])
        raise EntryWriteClient::Error, "the carried receipt of a committed legacy create is missing" if row.nil?

        hydrate(row, user_id: row["user_id"])
      end

      # The request's own If-Match wins; with none, the version the lookup read
      # is sent, so a change made after the policy check is refused.
      # :reek:LongParameterList
      def local_update(ownership:, found:, project:, attributes:, identity:)
        entry = found.entry
        row = local_write(ownership:, operation: :update, entry_id: entry.id, if_match: context.if_match || found.version,
                          body: update_body(entry, project:, attributes:), identity:,
                          idempotency_key: request_key(:update, entry.id))
        hydrate(row, user_id: entry.user_id)
      end

      # The stored answer to a committed update, held to the lookup's company,
      # id and scope checks, then to the caller's permission to read it back.
      def replayed_update(row, entry_id:, authorize_replay:, scope:)
        EntryLookup.replayed(context:, row:, entry_id:, scope:).tap { |entry| authorize_replay.call(entry) }
      end

      def local_bulk_move(ownership:, entries:, project:, identity:)
        ids = movable_entry_ids(entries, project).sort
        return false if ids.empty?

        answer = local_write(ownership:, operation: :bulk_move, body: { "entry_ids" => ids, "project_id" => project.id },
                             identity:, idempotency_key: local_bulk_key(:bulk_move, identity))
        reported?(answer, MOVED_RESULT)
      end

      def local_bulk_delete(ownership:, entries:, identity:)
        ids = entries.map(&:id).sort
        return false if ids.empty?

        answer = local_write(ownership:, operation: :bulk_delete, body: { "entry_ids" => ids }, identity:,
                             idempotency_key: local_bulk_key(:bulk_delete, identity))
        reported?(answer, DELETED_RESULT)
      end

      # A prepared bulk receipt is keyed over the requested ids, the key
      # bulk_write's replay looks up before the lookup runs. Keying it over
      # the ids written instead would let a retry whose found or movable ids
      # changed since the first attempt miss its receipt and write again.
      def local_bulk_key(operation, identity)
        bulk_request_key(operation, identity.fetch("entry_ids"))
      end

      # A forwarded bulk write is keyed over the ids it sent, which were the
      # ids found or movable at that time, and a rollback carries its receipt
      # into this store under that key. Those ids cannot be rebuilt from the
      # entries as they are now, so the receipt is found by its own stored
      # answer instead: a receipt of this actor and operation whose key is
      # this request's client key derived over the ids its answer lists. It
      # is then replayed as any receipt is; its fingerprint is Timekeeping's,
      # so a retry is refused as a reused key rather than written again.
      def replay_carried_bulk(ownership:, operation:, identity:)
        return if context.idempotency_key.nil?

        stored = local_owner.stored_bulk_receipts(operation:, company_id: context.company.id, actor: local_actor)
        carried = stored.find { |receipt| receipt.key == bulk_request_key(operation, receipt.entry_ids) }
        replay_local(ownership:, operation:, identity:, keys: [carried.key]) if carried
      end

      # The ids of the entries the legacy save would not skip.
      def movable_entry_ids(entries, project)
        entries.each { |entry| entry.project = project }
        entries.filter_map { |entry| entry.id if entry.valid?(:update) }
      end

      # One write to the prepared store's local owner, in the gateway's
      # transaction at the generation perform read. The body goes through JSON
      # so the owner receives the same values a forwarded write sends over the
      # wire. The receipt fingerprints identity, the request values the body is
      # built from, because the body also holds values read from current state
      # (a project's billing default, an entry's stored source fields, the ids
      # the lookup still finds) that the write itself can change.
      # :reek:LongParameterList
      def local_write(ownership:, operation:, body:, identity:, idempotency_key:, entry_id: nil, if_match: nil)
        outcome = local_owner.call(
          operation:, company_id: context.company.id, generation: ownership.generation, actor: local_actor,
          params: { "idempotency_key" => idempotency_key, "if_match" => if_match, "entry_id" => entry_id,
                    "body" => as_json_value(body) },
          identity: as_json_value(identity)
        )
        local_answer(operation, outcome)
      end

      # The local owner's stored answer to an earlier write of the same request,
      # or nil when there is none. Read before any check of current state, so a
      # retry whose first attempt committed replays instead of being refused by
      # what that attempt changed. keys are looked up in order and the first
      # stored answer wins, a key-reused refusal included, so a refusal never
      # falls through to a later key or to a write. body is sent only when
      # identity is nil, for a receipt that fingerprints the body itself.
      # :reek:LongParameterList
      def replay_local(ownership:, operation:, identity:, entry_id: nil, body: nil,
                       keys: replay_keys(request_key(operation, entry_id)))
        params = { "entry_id" => entry_id }
        params["body"] = as_json_value(body) unless body.nil?
        json_identity = identity.nil? ? nil : as_json_value(identity)

        keys.each do |key|
          outcome = local_owner.replay(
            operation:, company_id: context.company.id, generation: ownership.generation, actor: local_actor,
            params: params.merge("idempotency_key" => key), identity: json_identity
          )
          return local_answer(operation, outcome) unless outcome.nil?
        end
        nil
      end

      # The stored answer a retry is replayed from before any lookup or write:
      # the prepared store's receipt while it owns the entries, and a receipt
      # it wrote before a re-cutover while Timekeeping owns them. The legacy
      # store keeps receipts for creates only, which legacy_create reads.
      # :reek:LongParameterList
      def replay_committed(ownership:, owner:, operation:, identity:, entry_id: nil,
                           keys: replay_keys(request_key(operation, entry_id)))
        case owner
        when :prepared then replay_local(ownership:, operation:, identity:, entry_id:, keys:)
        when :timekeeping then replay_prepared_receipt(operation:, identity:, entry_id:, keys:)
        end
      end

      # A backstop for receipts the prepared store wrote before a re-cutover:
      # those under the raw client key from before keys were derived, and bulk
      # receipts keyed over the requested ids, which Timekeeping keys over the
      # ids it is sent instead. A re-cutover leaves them in this database,
      # while Timekeeping looks a retry up only under the key it is sent and
      # would write it again. The local owner's generation fence refuses every
      # request while Timekeeping owns the entries, so this read skips it; it
      # never writes. As in replay_local, the first stored answer wins.
      def replay_prepared_receipt(operation:, identity:, keys:, entry_id: nil)
        json_identity = as_json_value(identity)
        keys.each do |key|
          outcome = local_owner.stored_answer_for(
            operation:, company_id: context.company.id, actor: local_actor,
            params: { "idempotency_key" => key, "entry_id" => entry_id }, identity: json_identity
          )
          return local_answer(operation, outcome) unless outcome.nil?
        end
        nil
      end

      # The keys a retry may have been stored under: derived_key, then the raw
      # client key that receipts written before keys were derived used. A key
      # derived from the request id alone is new on every retry, so a request
      # without a client key looks up nothing.
      def replay_keys(derived_key)
        return [] if context.idempotency_key.nil?

        [derived_key, context.idempotency_key]
      end

      # A success answers its body; a refusal raises the error a Timekeeping
      # refusal raises, so callers and controllers handle both alike.
      def local_answer(operation, outcome)
        return outcome.body if (200..299).cover?(outcome.status)

        reason = outcome.body["reason"] if outcome.body.is_a?(Hash)
        raise EntryWriteClient.refusal_error(operation:, status: outcome.status, reason:)
      end

      def as_json_value(value)
        JSON.parse(JSON.generate(value))
      end

      # The request values of a create: the target user id as the write sends
      # it, the project, and the fields the writer may forward, before any
      # default is filled.
      def create_identity(user_id:, project:, fields:)
        { "user_id" => user_id, "project_id" => project.id, "fields" => fields.to_h.stringify_keys }
      end

      # The identity of a create request, built from the fields its writer may
      # forward.
      def request_create_identity(project:, attributes:, user_id:)
        fields = EntryWriteClient.forwarded_fields(attributes, actor_kind: context.actor_kind, operation: :create)
        create_identity(user_id:, project:, fields:)
      end

      def update_identity(project:, attributes:)
        { "project_id" => project.id,
          "fields" => EntryWriteClient.forwarded_fields(attributes, actor_kind: context.actor_kind, operation: :update) }
      end

      # The requested ids, as given, whatever the lookup still finds.
      def bulk_identity(entry_ids)
        { "entry_ids" => self.class.requested_entry_ids(entry_ids).sort }
      end

      # The signed-in user the context names, never a request value. The role
      # grants nothing: the local owner decides access from its own facts.
      def local_actor
        LocalOwner::Actor.user(user_id: context.actor.id, role: context.actor.primary_role(context.company))
      end

      # The local owner admits detach_entries only from a service actor. The
      # actor is bound to the agent's own company and to the detach operation
      # alone, and is named as the forwarded detach's token names the
      # monolith, so both stores record the same service on their audit rows.
      def local_detach(ownership:, agent:)
        actor = LocalOwner::Actor.service(name: ServiceToken::SUBJECT, company_id: agent.company_id,
                                          operations: [ServiceToken::DETACH_ENTRIES])
        outcome = local_owner.call(
          operation: :detach_entries, company_id: agent.company_id, generation: ownership.generation, actor:,
          params: { "agent_id" => agent.id,
                    "operation_id" => self.class.detach_operation_id(request_id: context.request_id,
                                                                     agent_id: agent.id) }
        )
        local_answer(:detach_entries, outcome).fetch("detached")
      end

      # The key a forwarded write of the same request sends, so a receipt
      # stored by either owner answers a retry after ownership moves. It is
      # seeded by the request's own Idempotency-Key, or by the request id when
      # the request sent none, as EntryWriteClient seeds it.
      def request_key(operation, entry_id = nil)
        EntryWriteClient.idempotency_key(request_id: key_seed, operation: operation.to_s, entry_id:)
      end

      def bulk_request_key(operation, entry_ids)
        EntryWriteClient.bulk_idempotency_key(request_id: key_seed, operation: operation.to_s, entry_ids:)
      end

      def key_seed
        context.idempotency_key || context.request_id
      end

      # The create body a forwarded and a local create both send. Only the
      # fields the writer may forward reach the draft, so a stray key such as
      # an actor or company_id is dropped instead of set on the draft.
      def create_body(user:, project:, attributes:)
        fields = EntryWriteClient.forwarded_fields(attributes, actor_kind: context.actor_kind, operation: :create)
        EntryWriteClient.create_body(user:, project:, attributes: checked_create_attributes(user:, project:,
                                                                                           attributes: fields),
                                     actor_kind: context.actor_kind)
      end

      # The update fields a forwarded update sends, as the local owner takes them.
      def update_body(entry, project:, attributes:)
        EntryWriteClient.forwarded_fields(normalized_update_attributes(entry, attributes).merge("project_id" => project.id),
                                          actor_kind: context.actor_kind, operation: :update)
      end

      def reported?(answer, result)
        Array(answer["results"]).any? { |entry_result| entry_result["result"] == result }
      end

      # The legacy store has no request receipts of its own, so a create the
      # client sent with its own Idempotency-Key stores one beside the entry,
      # in the same transaction. A retry whose first attempt committed then
      # replays the entry as that attempt committed it instead of recording
      # the time again; the copy is rebuilt from the receipt, never read from
      # the live row, so a later edit or delete never reaches the retry. A
      # key reused for different request values is refused. The lock makes a
      # retry that overlaps the first attempt wait for it; the receipt's
      # unique index backs that up. The receipt also keeps the body a
      # forwarded create of the same request would send, so a retry that
      # reaches Timekeeping after the first cutover can be answered there.
      # :reek:LongParameterList
      def legacy_create(project:, attributes:, user:, requested_user_id:, resolve_user:)
        key = context.idempotency_key
        return save_legacy_entry(project:, attributes:, user: user || resolve_user.call) if key.nil?

        scope = legacy_create_scope(key)
        LocalOwner::WriteSteps.lock_key(LEGACY_CREATE_LOCK, *scope.values)
        # Pruned here, through the expires_at index, so the receipts and the
        # entry copies they hold do not outlive the retry window; an expired
        # receipt under this key no longer answers.
        LegacyCreateReceipt.expired.delete_all
        receipt = LegacyCreateReceipt.find_by(scope)
        fingerprint = legacy_create_fingerprint(project:, attributes:, user_id: user ? user.id : requested_user_id)

        case LegacyCreateReplay.decision(stored_fingerprint: receipt&.fingerprint, fingerprint:)
        when :replay
          TimesheetEntry.instantiate(receipt.entry_attributes).tap(&:readonly!)
        when :key_reused
          raise EntryWriteClient.refusal_error(operation: :create, status: 422, reason: KEY_REUSED_REASON)
        when :write
          target = user || resolve_user.call
          # Built before the save, so its defaults are read from the state the
          # save itself reads.
          body = create_body(user: target, project:, attributes:)
          save_legacy_entry(project:, attributes:, user: target).tap do |entry|
            now = Time.current
            LegacyCreateReceipt.create!(**scope, fingerprint:, forwarded_body: forwarded_body_for(body, entry),
                                                 timesheet_entry_id: entry.id,
                                                 entry_attributes: entry.attributes_for_database,
                                                 created_at: now, expires_at: now + LegacyCreateReceipt::RETENTION)
          end
        end
      end

      # The legacy model casts any date text it can parse, such as a full
      # timestamp, while Timekeeping refuses a work_date that is not
      # YYYY-MM-DD before it reads its receipt. The carried body therefore
      # holds the date the legacy store saved, in that form, in the key's
      # original position. Returns the body as JSON text.
      def forwarded_body_for(body, entry)
        saved = body.key?("work_date") ? body.merge("work_date" => entry.work_date.iso8601) : body
        JSON.generate(saved)
      end

      def legacy_create_scope(key)
        { company_id: context.company.id, actor_kind: context.actor_kind, actor_id: context.actor.id, key: }
      end

      # A retry of a create whose first attempt committed in the legacy store
      # reaches Timekeeping after the first cutover, which carried that
      # attempt's receipt under its own key. The retry is matched to the
      # receipt by request values, as before the flip, and then resent with
      # the body the receipt stored, so Timekeeping answers it from that
      # receipt even when a default the body reads, such as the project's
      # billing default, changed in between. A key reused for different
      # request values is refused as in the legacy store, and nothing is sent.
      # The receipt is matched before the target user is resolved, as in
      # legacy_create: a resolver that checks the actor's current role would
      # otherwise refuse the retry of a create that already committed.
      # :reek:LongParameterList
      def forward_create(ownership:, project:, attributes:, user:, requested_user_id:, resolve_user:)
        target_user_id = user ? user.id : requested_user_id
        receipt = carried_legacy_create(project:, attributes:, user_id: target_user_id)
        return forward_carried_create(ownership:, receipt:) if receipt

        stored = replay_prepared_receipt(
          operation: :create, identity: request_create_identity(project:, attributes:, user_id: target_user_id),
          keys: replay_keys(request_key(:create))
        )
        return hydrate(stored, user_id: stored["user_id"]) if stored

        target = user || resolve_user.call
        row = write_client.create_entry(context:, generation: ownership.generation,
                                        body: create_body(user: target, project:, attributes:))
        hydrate(row, user_id: target.id)
      end

      # The stored body names the user the first attempt wrote for, so the
      # answer is hydrated for that user.
      def forward_carried_create(ownership:, receipt:)
        body = JSON.parse(receipt.forwarded_body)
        carried_key = LegacyCreateReplay.carried_key(actor_kind: receipt.actor_kind, key: receipt.key)
        row = write_client.create_entry(context:, generation: ownership.generation, body:, idempotency_key: carried_key)
        hydrate(row, user_id: body.fetch("user_id"))
      end

      # The unexpired legacy receipt this request retries, or nil when it
      # sent no key of its own or none was stored for it. An expired receipt
      # was never carried into Timekeeping, so it answers nothing here either.
      def carried_legacy_create(project:, attributes:, user_id:)
        key = context.idempotency_key
        return if key.nil?

        receipt = LegacyCreateReceipt.unexpired.find_by(legacy_create_scope(key))
        fingerprint = legacy_create_fingerprint(project:, attributes:, user_id:)
        case LegacyCreateReplay.decision(stored_fingerprint: receipt&.fingerprint, fingerprint:)
        when :replay then receipt
        when :key_reused then raise EntryWriteClient.refusal_error(operation: :create, status: 422,
                                                                   reason: KEY_REUSED_REASON)
        end
      end

      def save_legacy_entry(project:, attributes:, user:)
        project.timesheet_entries.new(attributes).tap do |entry|
          entry.user = user
          entry.save!
        end
      end

      # The same request values a prepared create's receipt fingerprints.
      def legacy_create_fingerprint(project:, attributes:, user_id:)
        LegacyCreateReplay.fingerprint(as_json_value(request_create_identity(project:, attributes:, user_id:)))
      end

      # The legacy model refuses a create already marked billed, so a billed
      # row is created unbilled and billed in the same transaction.
      def import_legacy(user:, project:, final:)
        billed = billed?(final)
        project.timesheet_entries.new(create_time_attributes(final)).tap do |entry|
          entry.user = user
          # The project was resolved inside the context's company, so the
          # entry's company is known without a query per imported row.
          entry.association(:company).target = context.company
          entry.save!
          entry.update!(bill_status: :billed) if billed
        end
      end

      def import_forwarded(ownership:, user:, project:, final:, idempotency_key:)
        row = write_client.create_entry(context:, generation: ownership.generation,
                                        body: import_body(user:, project:, final:), idempotency_key:)
        hydrate(row, user_id: user.id)
      end

      # The draft is validated with the status the legacy store would create
      # it with, and the one create sent carries the row's final status.
      def import_body(user:, project:, final:)
        checked = checked_create_attributes(user:, project:, attributes: create_time_attributes(final))
        checked = checked.merge("bill_status" => "billed") if billed?(final)
        EntryWriteClient.import_create_body(user:, project:, attributes: checked, source: final)
      end

      def billed?(attributes)
        attributes["bill_status"].to_s == "billed"
      end

      def create_time_attributes(final)
        billed?(final) ? final.merge("bill_status" => "unbilled") : final
      end

      # The one place a refusal is counted, so each refused write emits exactly
      # one event whether the fence, the local owner or Timekeeping refused it.
      def perform(expected_generation)
        ActiveRecord::Base.transaction do
          ownership = admitted_ownership(expected_generation)
          owner = EntryOwner.for(ownership)
          next yield(ownership, owner) unless owner == :legacy

          LegacyWriterMark.call(ActiveRecord::Base.connection) { yield(ownership, owner) }
        end
      rescue OwnershipMoving, StaleGeneration => refusal
        Rails.event.notify(EntryWriteRefused.new(context, reason: REFUSAL_REASONS.fetch(refusal.class)))
        raise
      end

      # Refuses a missing row, a handoff in progress, and any owner or store
      # value this code does not know, so lost or unexpected ownership state
      # never routes a write to the legacy table.
      def admitted_ownership(expected_generation)
        ownership = ownership_reader.call
        raise OwnershipMoving unless admissible?(ownership)
        raise StaleGeneration if !expected_generation.nil? && expected_generation != ownership.generation

        ownership
      end

      def admissible?(ownership)
        !ownership.nil? &&
          !ownership.admission_closed? &&
          TimekeepingOwnership::OWNERS.include?(ownership.owner) &&
          TimekeepingOwnership::MONOLITH_STORES.include?(ownership.monolith_store)
      end

      # Runs the legacy model's create validations on an unsaved draft before
      # forwarding, so a create the legacy store refuses today, such as one
      # already marked billed, is refused the same way (422) and never reaches
      # Timekeeping. The draft also fills bill_status from the project when the
      # request leaves it out (non_billable for a non-billable project), which
      # Timekeeping's own default (unbilled) would get wrong.
      #
      # Every field the writer forwards beyond the web form's own is copied
      # from the draft too, so the body carries what a save would store: the
      # source inferred from its metadata, the metadata sliced, the proof
      # metadata trimmed. For an agent create the validation also runs
      # TimesheetEntry#validate_agent_exists, whose share lock on the agent row,
      # taken after the ownership row, holds until this transaction ends, after
      # the forwarded call. An agent destroy that locks the row first makes the
      # create fail validation (422); one that waits detaches the new entry.
      def checked_create_attributes(user:, project:, attributes:)
        draft = project.timesheet_entries.new(attributes)
        draft.user = user
        draft.validate!
        copied = ["bill_status"] + (EntryWriteClient::FORWARDED_FIELDS.fetch(context.actor_kind).fetch(:create) -
                                    EntryWriteClient::EDIT_FIELDS)
        attributes.to_h.stringify_keys.merge(copied.index_with { |field| draft.read_attribute(field) })
      end

      # An update that sets either source field sends both as a save would
      # store them, reading the one it leaves out from the entry as it is.
      def normalized_update_attributes(entry, attributes)
        fields = attributes.to_h.stringify_keys
        return fields unless fields.keys.intersect?(EntryWriteClient::SOURCE_FIELDS)

        fields.merge(TimesheetEntry.normalized_source_fields(
          source: fields.fetch("source", entry.source),
          source_metadata: fields.fetch("source_metadata", entry.source_metadata)
        ))
      end

      def find_authorized(ownership:, entry_id:, authorize:, scope:)
        EntryLookup.find(ownership:, context:, entry_id:, read_client:, scope:).tap do |found|
          authorize.call(found.entry)
        end
      end

      # The replay can only return a delete this actor already committed: with
      # no stored receipt Timekeeping answers not found and writes nothing. A
      # service that predates the replay header refuses the request's fixed
      # If-Match as a version conflict, which is answered as the same not
      # found, so every miss looks alike whatever the entry's state. The
      # replayed entry passes the lookup's own checks and the policy before
      # the delete is reported as done.
      def replay_timekeeping_destroy(ownership:, entry_id:, authorize:, scope:)
        row = begin
          write_client.replay_destroy_entry(context:, generation: ownership.generation, entry_id:)
        rescue EntryWriteClient::Conflict
          raise EntryLookup.not_found
        end
        authorize.call(EntryLookup.replayed(context:, row:, entry_id:, scope:))
        true
      end

      # The prepared store's lookup hides a discarded entry too, so a retried
      # delete whose answer was lost asks the local owner for its stored
      # receipt. The local owner reads the receipt before it checks If-Match,
      # and the fixed If-Match is never a version, so a live entry is refused
      # as a version conflict instead of discarded. Every miss answers not found.
      def replay_local_destroy(ownership:, entry_id:, authorize:, scope:)
        row = begin
          local_write(ownership:, operation: :destroy, entry_id:, if_match: EntryWriteClient::REPLAY_ONLY_IF_MATCH,
                      body: {}, identity: {}, idempotency_key: request_key(:destroy, entry_id))
        rescue EntryWriteClient::Conflict
          raise EntryLookup.not_found
        end
        authorize.call(EntryLookup.replayed(context:, row:, entry_id:, scope:))
        true
      end

      # A forwarded answer outside the company or for another user is never
      # rendered. The write may already have committed in Timekeeping, so this
      # is the retryable unavailable error, not a not-found.
      def hydrate(row, user_id:)
        entry = EntryReader.hydrate([row], company: context.company, user_id:).first
        raise EntryWriteClient::Error, "Timekeeping entry answer did not match the request" if entry.nil?

        entry
      end
  end
end

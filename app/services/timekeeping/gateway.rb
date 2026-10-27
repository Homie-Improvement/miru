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

    # The local-owner dependency until the prepared monolith's entry writer
    # exists. The prepared store must never be written by anything else, so
    # every call refuses as a retryable ownership move rather than writing.
    class UnavailableLocalOwner
      def find_entry(**)
        raise OwnershipMoving
      end

      def create_entry(**)
        raise OwnershipMoving
      end

      def update_entry(**)
        raise OwnershipMoving
      end

      def destroy_entry(**)
        raise OwnershipMoving
      end

      def detach_agent_entries(**)
        raise OwnershipMoving
      end
    end

    # Reads the ownership row under a share lock, or nil when it is missing.
    # Never TimekeepingOwnership.current, whose RecordNotFound would answer a
    # write with 404 instead of refusing it.
    module LockedOwnership
      def self.call
        TimekeepingOwnership.lock("FOR SHARE").find_by(id: TimekeepingOwnership::SINGLETON_ID)
      end
    end

    # Marks the transaction's legacy writes so a database guard can tell them
    # from writes that bypass the gateway. A fixed literal, as
    # ProjectionConsumer::MARK_PROJECTION_WRITER_SQL is.
    MARK_LEGACY_WRITER_SQL = "SET LOCAL miru.writer = 'legacy_gateway'"
    READ_WRITER_SQL = "SELECT current_setting('miru.writer', true)"
    RESTORE_WRITER_SQL = "SELECT set_config('miru.writer', ?, true)"

    REFUSAL_REASONS = { OwnershipMoving => "ownership_moving", StaleGeneration => "stale_generation" }.freeze

    # Fixed namespace for the version 5 UUIDs used as detach operation ids.
    DETACH_OPERATION_NAMESPACE = "3d0f7a52-8c1e-4b6a-9f2d-5e7c1a9b4d60"

    attr_reader :context, :local_owner, :write_client, :read_client, :service_client, :ownership_reader

    # :reek:LongParameterList
    def initialize(context:, local_owner: UnavailableLocalOwner.new, write_client: EntryWriteClient.new,
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
          local_owner.detach_agent_entries(context:, agent:)
        when :timekeeping
          service_client.detach_agent_entries(
            company_id: agent.company_id, agent_id: agent.id, generation: ownership.generation,
            operation_id: self.class.detach_operation_id(request_id: context.request_id, agent_id: agent.id),
            request_id: context.request_id
          )
        end
      end
    end

    # user and project are records the caller already resolved inside the
    # context's company. Returns the created TimesheetEntry: saved on the
    # legacy branch, unsaved when another store owns the entries.
    def create(user:, project:, attributes:, expected_generation: nil)
      perform(expected_generation) do |ownership, owner|
        case owner
        when :legacy
          project.timesheet_entries.new(attributes).tap do |entry|
            entry.user = user
            entry.save!
          end
        when :prepared
          local_owner.create_entry(context:, user:, project:, attributes:)
        when :timekeeping
          body = EntryWriteClient.create_body(user:, project:, attributes: checked_create_attributes(user:, project:,
                                                                                                    attributes:))
          hydrate(write_client.create_entry(context:, generation: ownership.generation, body:), user_id: user.id)
        end
      end
    end

    # authorize is called with the entry found in the owning store, inside the
    # transaction and before the write, so the policy decides on the copy the
    # write will change.
    def update(entry_id:, project:, attributes:, authorize:, expected_generation: nil, scope: :company)
      perform(expected_generation) do |ownership, owner|
        found = find_authorized(ownership:, entry_id:, authorize:, scope:)
        case owner
        when :legacy
          found.entry.tap do |entry|
            entry.project = project
            entry.update!(attributes)
          end
        when :prepared
          local_owner.update_entry(context:, entry: found.entry, project:, attributes:)
        when :timekeeping
          body = attributes.to_h.stringify_keys.merge("project_id" => project.id)
          row = write_client.update_entry(context:, generation: ownership.generation, entry_id: found.entry.id,
                                          version: found.version, body:)
          hydrate(row, user_id: found.entry.user_id)
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
    def destroy(entry_id:, authorize:, expected_generation: nil, scope: :company)
      perform(expected_generation) do |ownership, owner|
        found = begin
          find_authorized(ownership:, entry_id:, authorize:, scope:)
        rescue ActiveRecord::RecordNotFound
          raise unless owner == :timekeeping

          next replay_timekeeping_destroy(ownership:, entry_id:, authorize:, scope:)
        end
        case owner
        when :legacy
          found.entry.discard!
        when :prepared
          local_owner.destroy_entry(context:, entry: found.entry)
        when :timekeeping
          write_client.destroy_entry(context:, generation: ownership.generation, entry_id: found.entry.id,
                                     version: found.version)
        end
        true
      end
    end

    private

      # The one place a refusal is counted, so each refused write emits exactly
      # one event whether the fence, the local owner or Timekeeping refused it.
      def perform(expected_generation)
        ActiveRecord::Base.transaction do
          ownership = admitted_ownership(expected_generation)
          owner = EntryOwner.for(ownership)
          next yield(ownership, owner) unless owner == :legacy

          as_legacy_writer { yield(ownership, owner) }
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
          ownership.handoff_step.blank? &&
          TimekeepingOwnership::OWNERS.include?(ownership.owner) &&
          TimekeepingOwnership::MONOLITH_STORES.include?(ownership.monolith_store)
      end

      # Runs the legacy model's create validations on an unsaved draft before
      # forwarding, so a create the legacy store refuses today, such as one
      # already marked billed, is refused the same way (422) and never reaches
      # Timekeeping. The draft also fills bill_status from the project when the
      # request leaves it out (non_billable for a non-billable project), which
      # Timekeeping's own default (unbilled) would get wrong.
      def checked_create_attributes(user:, project:, attributes:)
        draft = project.timesheet_entries.new(attributes)
        draft.user = user
        draft.validate!
        attributes.to_h.stringify_keys.merge("bill_status" => draft.bill_status)
      end

      def find_authorized(ownership:, entry_id:, authorize:, scope:)
        EntryLookup.find(ownership:, context:, entry_id:, local_owner:, read_client:, scope:).tap do |found|
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

      # SET LOCAL lasts until the outermost transaction ends. When the gateway
      # joins a caller's transaction, the previous value is put back after the
      # write, so the caller's later statements are not marked as the gateway's.
      # That holds when the write raises too, since the caller may rescue and
      # go on in the same transaction.
      def as_legacy_writer
        connection = ActiveRecord::Base.connection
        previous = connection.select_value(READ_WRITER_SQL)
        connection.execute(MARK_LEGACY_WRITER_SQL)
        begin
          result = yield
        rescue StandardError
          restore_writer_after_failure(connection, previous)
          raise
        end
        restore_writer(connection, previous)
        result
      end

      def restore_writer(connection, previous)
        connection.select_value(ActiveRecord::Base.sanitize_sql_array([RESTORE_WRITER_SQL, previous.to_s]))
      end

      # A failed SQL statement aborts the whole transaction, which can then only
      # roll back, and the rollback clears the setting. The restore cannot run
      # then, and its own error must not hide the write's.
      def restore_writer_after_failure(connection, previous)
        restore_writer(connection, previous)
      rescue ActiveRecord::StatementInvalid
        nil
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

# frozen_string_literal: true

require "digest"

module Timekeeping
  class LocalOwner
    # The prepared monolith's prepare, commit and abort of an invoice's
    # reservations, for background services, against the monolith's own
    # reservations, invoice_operations, entries, entry_audits,
    # entry_outbox_items and idempotency_records tables. It mirrors the
    # Timekeeping service's Timekeeping::ReservationOperations and decides
    # with the same TimekeepingRules::ReservationDecision.
    #
    # ServiceAccess decides first, before any lock or read, so a refused
    # caller never sees a stored answer. Then everything runs in one
    # savepoint, in this order:
    #
    # 1. Lock the operation key (company, service name, operation_id), then
    #    the company's invoice with Invoices::OperationLock, the lock
    #    Invoices::PreparedReservations runs under, so the two writers on one
    #    invoice wait in turn.
    # 2. Read the ownership generation FOR SHARE NOWAIT. A body generation
    #    that is not the admitted one is stale_generation. The service
    #    replays before this check; this order is deliberately the reverse,
    #    so a retry at an old generation is refused even when its earlier
    #    answer is stored. A billing write holds the ownership row FOR SHARE
    #    before it takes the invoice lock, so with a handoff's update queued
    #    on that row a waiting read here could close a lock cycle; NOWAIT
    #    answers stale_generation instead of waiting.
    # 3. Replay the stored answer: the operation row for prepare, the receipt
    #    for commit and abort.
    # 4. Lock the entries involved FOR UPDATE, by company, in id order.
    # 5. Read their reservations and decide.
    # 6. Change the reservations. Each entry whose locked flag flips gets
    #    version + 1, one audit row and one outbox snapshot.
    # 7. Store the operation row, and for commit and abort the receipt.
    #
    # A refusal decided before step 6 writes nothing. One decided after it
    # (an unpublishable entry) raises inside the savepoint and is answered
    # after the rollback. checkpoint is called with names from
    # LocalOwner::STEPS as each step finishes.
    class ReservationOperations
      ACTOR_TYPE = "service"
      # The reservation wire carries no invoice status, so the desired set
      # prepare stored is applied as a draft's, as the service does.
      WIRE_INVOICE_STATUS = TimekeepingRules::ReservationDecision::DRAFT_STATUS
      PROVISIONAL = TimekeepingRules::ReservationDecision::PROVISIONAL
      COMMITTED = TimekeepingRules::ReservationDecision::COMMITTED
      DISPOSITIONS = Invoices::ReservationRequest::DISPOSITIONS
      ACTIVE, RETAINED = DISPOSITIONS
      PREPARED = "prepared"
      ABORTED = "aborted"
      ROW_LOCK = "FOR UPDATE"
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      ROUTES = { prepare: :prepare, commit: :commit, abort: :abort_operation }.freeze

      # What commit and abort answer for an operation that is already
      # terminal: the first of them won, so this one changes nothing.
      TERMINAL_ANSWERS = {
        commit: { "reserved" => 0, "released" => 0 }.freeze,
        abort: { "dropped" => 0 }.freeze
      }.freeze

      # One request, its values checked: invoice_id is an Integer,
      # operation_id a UUID string, and for prepare disposition is one of
      # DISPOSITIONS and entry_ids are Integers.
      Request = Data.define(:route, :company_id, :actor_name, :invoice_id, :operation_id, :disposition, :entry_ids)

      # The two tables have no model the monolith shares. ServiceCommands
      # reads Reservation too, to find an invoice's committed entries.
      class Reservation < ApplicationRecord
        self.table_name = "reservations"
      end

      class InvoiceOperation < ApplicationRecord
        self.table_name = "invoice_operations"
      end

      private_constant :Request, :InvoiceOperation

      # :reek:LongParameterList
      def initialize(operation:, company_id:, generation:, actor:, params:, checkpoint:)
        @route = operation.to_sym
        raise ArgumentError, "unknown operation #{operation.inspect}" unless ROUTES.key?(@route)

        @company_id = company_id
        @generation = generation
        @actor = actor
        @params = params
        @checkpoint = checkpoint
      end

      def call
        access = ServiceAccess.call(actor:, operation: route, company_id:)
        return Outcome.refusal(access) unless access == :ok

        @request = build_request
        return Outcome.refusal(:invalid_request) unless request

        attempt
      rescue ReceiptTaken
        # A backstop: the operation and invoice locks normally stop two
        # writers from both reaching an insert. The failed attempt has rolled
        # back every row it wrote. Running the steps again checks the
        # generation first and then replays what is stored now.
        attempt
      end

      private

        attr_reader :route, :company_id, :generation, :actor, :params, :checkpoint, :request

        # Each attempt runs in its own savepoint, so a refusal raised after a
        # write, or a NOWAIT read that found the row locked, rolls back every
        # row the attempt wrote and leaves the caller's transaction usable.
        def attempt
          ApplicationRecord.transaction(requires_new: true) { write }
        rescue WriteSteps::OwnershipQueued
          Outcome.refusal(:stale_generation)
        rescue WriteSteps::UnpublishableRows => error
          error.outcome
        end

        def write
          lock_operation_key
          checkpoint.call(:operation_key_locked)
          Invoices::OperationLock.acquire!(ApplicationRecord.connection, company_id:, invoice_id: request.invoice_id)
          stored_generation = WriteSteps.locked_generation_nowait
          return Outcome.refusal(:stale_generation) unless WriteSteps.generation_matches?(generation, stored_generation)

          checkpoint.call(:generation_checked)
          stored = stored_answer
          checkpoint.call(:operation_checked)
          return stored if stored

          send(ROUTES.fetch(route), stored_generation)
        end

        # Only the params keys below are read, so a company_id or actor field
        # elsewhere in params changes nothing.
        def build_request
          invoice_id = WriteSteps.id_value(params["invoice_id"])
          operation_id = params["operation_id"]
          return unless invoice_id && operation_id.is_a?(String) && UUID.match?(operation_id)

          disposition, entry_ids = route == :prepare ? prepare_values : [nil, nil]
          return if route == :prepare && entry_ids.nil?

          Request.new(route:, company_id:, actor_name: actor.name, invoice_id:, operation_id:, disposition:, entry_ids:)
        end

        # [disposition, entry_ids], with entry_ids nil when either is invalid.
        def prepare_values
          disposition = params["disposition"]
          raw_ids = params["entry_ids"]
          return [disposition, nil] unless DISPOSITIONS.include?(disposition) && raw_ids.is_a?(Array)

          entry_ids = raw_ids.map { |id| WriteSteps.id_value(id) }
          [disposition, entry_ids.all? ? entry_ids : nil]
        end

        # Only writers with the same company, service and operation_id wait on
        # each other.
        def lock_operation_key
          WriteSteps.lock_key(company_id, ACTOR_TYPE, request.actor_name, request.operation_id)
        end

        # Prepare answers from its operation row with the operation's current
        # state; commit and abort answer from their receipt. nil when neither
        # is stored yet.
        def stored_answer
          if route == :prepare
            operation = find_operation
            operation && prepare_replay(operation)
          else
            receipt = find_receipt
            receipt && receipt_answer(receipt)
          end
        end

        # Operations

        def prepare(stored_generation)
          unresolved = unresolved_refusal
          return unresolved if unresolved

          entries = lock_entries(request.entry_ids)
          checkpoint.call(:rows_locked)
          decision = prepare_decision(entries)
          return conflict_refusal(decision[:conflicts]) unless decision[:conflicts].empty?

          checkpoint.call(:rules_checked)
          store_prepare(entries, decision[:reserve], stored_generation)
        end

        def prepare_decision(entries)
          kept_ids = entries.filter_map { |entry| entry.id if entry.discarded_at.nil? }
          TimekeepingRules::ReservationDecision.call(
            current: prepare_reservations(kept_ids), desired: request.entry_ids,
            disposition: request.disposition, invoice_status: WIRE_INVOICE_STATUS
          )
        end

        # The id is taken first so the provisional rows can name their
        # operation, while the operation row itself is stored last.
        def store_prepare(entries, reserve_ids, stored_generation)
          operation_row_id = next_operation_id
          reserve_provisionally(operation_row_id, reserve_ids + retained_by_this)
          checkpoint.call(:reservations_written)
          record_flips(entries, stored_generation)
          operation = insert_operation(operation_row_id, stored_generation)
          checkpoint.call(:operation_written)
          prepare_answer(operation)
        end

        def commit(stored_generation)
          operation = find_operation
          return Outcome.refusal(:not_found) unless operation&.invoice_id == request.invoice_id
          return finish(TERMINAL_ANSWERS.fetch(:commit)) unless operation.state == PREPARED

          entries = lock_entries((own_provisional(operation) + invoice_committed).pluck(:entry_id))
          checkpoint.call(:rows_locked)
          claimed_ids = own_provisional(operation).pluck(:entry_id)
          held_ids = invoice_committed.pluck(:entry_id)
          # A claimed entry this invoice already held is kept, not newly reserved.
          reserved_ids = claimed_ids - held_ids
          released_ids = TimekeepingRules::ReservationDecision.call(
            current: decision_reservations(held_ids), desired: operation.desired_entry_ids,
            disposition: operation.disposition, invoice_status: WIRE_INVOICE_STATUS
          )[:release]
          checkpoint.call(:rules_checked)

          make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
          checkpoint.call(:reservations_written)
          record_flips(entries, stored_generation)
          operation.update!(state: COMMITTED, finished_at: Time.current)
          finish("reserved" => reserved_ids.size, "released" => released_ids.size)
        end

        def abort_operation(stored_generation)
          operation = find_operation
          return Outcome.refusal(:not_found) unless operation&.invoice_id == request.invoice_id
          return finish(TERMINAL_ANSWERS.fetch(:abort)) unless operation.state == PREPARED

          entries = lock_entries(own_provisional(operation).pluck(:entry_id))
          checkpoint.call(:rows_locked)
          # A claim on an entry this invoice still holds as its retained owner
          # gives nothing up, so it is not counted as dropped.
          dropped = own_provisional(operation).where.not(entry_id: invoice_committed.select(:entry_id)).delete_all
          own_provisional(operation).delete_all
          checkpoint.call(:reservations_written)
          record_flips(entries, stored_generation)
          operation.update!(state: ABORTED, finished_at: Time.current)
          finish("dropped" => dropped)
        end

        # Reservations

        # The company's entries with these ids, discarded ones included,
        # locked in id order so two writers over the same entries wait in
        # turn. The reservation flag is read in a second statement once the
        # locks are held: a statement that waited on a lock still evaluates its
        # subquery against the snapshot taken before the wait.
        def lock_entries(entry_ids)
          return [] if entry_ids.empty?

          ids = LocalEntry.where(company_id:, id: entry_ids.uniq).order(:id).lock(ROW_LOCK).pluck(:id)
          WriteSteps.reserved_rows(company_id, ids).values_at(*ids)
        end

        # Each entry's reservations in the form ReservationDecision reads, seen
        # from the request's invoice. An id left out is one outside the
        # company, discarded or missing, which the decision reports as
        # not_found.
        def decision_reservations(entry_ids)
          found = Reservation.where(company_id:, entry_id: entry_ids).group_by(&:entry_id)
          entry_ids.index_with do |entry_id|
            found.fetch(entry_id, []).map do |reservation|
              { invoice: reservation.invoice_id == request.invoice_id ? :this : :other, state: reservation.state,
                disposition: reservation.disposition }
            end
          end
        end

        # The reservations prepare decides on, with the claims other kept
        # invoices make through their lines or active holdings. A sent
        # invoice's added line passes admit and writes no reservation row, so
        # reading rows alone would hand that entry to a second invoice. As
        # Invoices::PreparedReservations does, an active committed row comes
        # first, then another kept invoice's active claim, then a row that
        # only retains the entry, this invoice's own included.
        def prepare_reservations(kept_ids)
          claims = Invoices::EntryClaims.new(company_id, kept_ids)
          decision_reservations(kept_ids).to_h do |entry_id, reservations|
            [entry_id, with_other_active_claim(reservations, claims.other_active_claim(entry_id, request.invoice_id))]
          end
        end

        def with_other_active_claim(reservations, other_claim)
          committed, provisional = reservations.partition { |reservation| reservation[:state] == COMMITTED }
          return reservations if other_claim.nil? || committed.any? { |reservation| reservation[:disposition] == ACTIVE }

          provisional + [{ invoice: :other, state: COMMITTED, disposition: ACTIVE }]
        end

        # The desired entries this invoice already holds only as a retained
        # owner. A successor's prepare may take such an entry, so this
        # operation claims each one with a provisional row as well: whichever
        # operation prepares first holds it.
        def retained_by_this
          invoice_committed.where(entry_id: request.entry_ids, disposition: RETAINED).pluck(:entry_id)
        end

        def reserve_provisionally(operation_row_id, entry_ids)
          return if entry_ids.empty?

          now = Time.current
          Reservation.insert_all!(entry_ids.map do |entry_id|
            { company_id:, entry_id:, invoice_id: request.invoice_id, state: PROVISIONAL,
              disposition: request.disposition, operation_id: request.operation_id,
              invoice_operation_id: operation_row_id, created_at: now }
          end)
        end

        # Order matters for the one-committed-per-entry index: a retained
        # committed row on an entry this operation claimed gives way first,
        # then the released rows go, then this operation's provisional rows
        # become committed, and every row the invoice holds takes the
        # operation's disposition. An active committed row is never removed:
        # prepare refuses such an entry to every other invoice.
        def make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
          Reservation.where(company_id:, entry_id: claimed_ids, state: COMMITTED, disposition: RETAINED).delete_all
          invoice_committed.where(entry_id: released_ids).delete_all
          own_provisional(operation).update_all(state: COMMITTED)
          invoice_committed.update_all(disposition: operation.disposition)
        end

        # Rows are selected by the owning operation's row id, never by
        # operation_id alone, so another service's operation with the same id
        # is not touched.
        def own_provisional(operation)
          Reservation.where(company_id:, invoice_operation_id: operation.id, state: PROVISIONAL)
        end

        def invoice_committed
          Reservation.where(company_id:, invoice_id: request.invoice_id, state: COMMITTED)
        end

        def record_flips(entries, stored_generation)
          WriteSteps.record_flips(
            company_id:, entries:, actor: { actor_type: ACTOR_TYPE, actor_name: request.actor_name },
            action: route.to_s, generation: stored_generation, checkpoint:
          )
        end

        # Operation rows

        def find_operation
          InvoiceOperation.find_by(company_id:, actor_name: request.actor_name, operation_id: request.operation_id)
        end

        def next_operation_id
          InvoiceOperation.connection.select_value(
            "SELECT nextval(pg_get_serial_sequence('invoice_operations', 'id'))"
          ).to_i
        end

        def insert_operation(operation_row_id, stored_generation)
          InvoiceOperation.create!(
            id: operation_row_id, company_id:, invoice_id: request.invoice_id, operation_id: request.operation_id,
            actor_name: request.actor_name, state: PREPARED, desired_entry_ids: request.entry_ids,
            disposition: request.disposition, generation: stored_generation, created_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique => error
          raise ReceiptTaken, error.message
        end

        # A prepare replayed with another invoice, disposition or entry set
        # is a reused key, not a replay.
        def prepare_replay(operation)
          same = [operation.invoice_id, operation.disposition, operation.desired_entry_ids] ==
                 [request.invoice_id, request.disposition, request.entry_ids]
          same ? prepare_answer(operation) : Outcome.refusal(:idempotency_key_reused)
        end

        def prepare_answer(operation)
          entries = operation.desired_entry_ids.map { |entry_id| { "entry_id" => entry_id, "company_id" => company_id } }
          Outcome.success(200, "operation_id" => operation.operation_id, "state" => operation.state, "entries" => entries)
        end

        # Another operation still prepared for this invoice must be committed
        # or aborted first; the caller retries it by the id this names.
        def unresolved_refusal
          open = InvoiceOperation.find_by(company_id:, invoice_id: request.invoice_id, state: PREPARED)
          return unless open

          Outcome.success(STATUS.fetch(:unresolved_operation),
                          "reason" => "unresolved_operation", "operation_id" => open.operation_id, "retryable" => true)
        end

        def conflict_refusal(conflicts)
          body = conflicts.map { |conflict| { "entry_id" => conflict[:entry_id], "reason" => conflict[:reason].to_s } }
          Outcome.success(STATUS.fetch(:conflict), "reason" => "conflict", "conflicts" => body)
        end

        # Receipts

        def finish(payload)
          outcome = Outcome.success(200, payload)
          store_receipt(outcome)
          checkpoint.call(:receipt_written)
          outcome
        end

        # Service receipts carry the service name and no actor_id.
        def store_receipt(outcome)
          Receipt.create!(
            company_id:, actor_type: ACTOR_TYPE, actor_id: nil, actor_name: request.actor_name, operation: route.to_s,
            key: request.operation_id, fingerprint:, status: outcome.status, body: JSON.generate(outcome.body),
            created_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique => error
          raise ReceiptTaken, error.message
        end

        def find_receipt
          Receipt.find_by(company_id:, actor_type: ACTOR_TYPE, actor_name: request.actor_name, operation: route.to_s,
                          key: request.operation_id)
        end

        def receipt_answer(receipt)
          return Outcome.refusal(:idempotency_key_reused) unless receipt.fingerprint == fingerprint

          Outcome.new(status: receipt.status, body: JSON.parse(receipt.body))
        end

        # Commit and abort act only on what prepare stored, so the invoice is
        # all a replay must repeat.
        def fingerprint
          Digest::SHA256.hexdigest(JSON.generate("invoice_id" => request.invoice_id))
        end
    end
  end
end

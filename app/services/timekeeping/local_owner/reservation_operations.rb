# frozen_string_literal: true

require "digest"

module Timekeeping
  class LocalOwner
    # Carries out one prepare, commit or abort of an invoice's reservations on
    # the prepared monolith's own tables, in one savepoint, so the reservation
    # change, the locked flips it causes (entry version, audit and outbox
    # rows), the operation row and the receipt commit together or not at all.
    # It mirrors Timekeeping::ReservationOperations in the Timekeeping service,
    # with one difference in order, in these steps:
    #
    # 1. Lock the operation key (company, service, operation_id), then the
    #    company's invoice, so commit and abort of one operation, and prepares
    #    for one invoice, wait in turn.
    # 2. Read the admitted generation FOR SHARE. A body generation that is not
    #    that generation is stale_generation. This comes before the stored
    #    answer, so a retry at an old generation is refused even when its
    #    earlier answer is stored; the service replays first.
    # 3. Re-read the stored answer: the operation row for prepare, the receipt
    #    for commit and abort.
    # 4. Lock the entries involved FOR UPDATE in id order, then read their
    #    reservations and decide with TimekeepingRules::ReservationDecision.
    # 5. Change the reservations. Each entry whose locked flag flips gets
    #    version + 1, one audit row and, under the outbox lock, one snapshot.
    # 6. Store the operation state, and for commit and abort the receipt.
    #
    # checkpoint is called with each step's name from STEPS as it finishes, so
    # a spec can fail the write at a known point; an error it raises is never
    # rescued here.
    class ReservationOperations
      # The reservation wire carries no invoice status, so the desired set is
      # applied as a draft's, as the Timekeeping service does. The decision
      # therefore reads no invoice row.
      WIRE_INVOICE_STATUS = TimekeepingRules::ReservationDecision::DRAFT_STATUS
      ACTOR_TYPE = "service"
      INVOICE_LOCK = "invoice"
      PROVISIONAL = TimekeepingRules::ReservationDecision::PROVISIONAL
      COMMITTED = TimekeepingRules::ReservationDecision::COMMITTED
      RETAINED = "retained"
      DISPOSITIONS = RESERVATIONS.fetch("dispositions").freeze
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # Operation states. COMMITTED names both a committed operation and a
      # committed reservation, as the contract does.
      PREPARED = "prepared"
      ABORTED = "aborted"

      ROUTES = { prepare: :prepare, commit: :commit, abort: :abort_operation }.freeze

      # What commit and abort answer for an operation that is already terminal:
      # the first of them won, so this one changes nothing.
      TERMINAL_ANSWERS = {
        commit: { "reserved" => 0, "released" => 0 }.freeze,
        abort: { "dropped" => 0 }.freeze
      }.freeze

      # The tables these writes touch have no other model in the monolith.
      # reservations has no primary key.
      class Reservation < ApplicationRecord
        self.table_name = "reservations"
        self.primary_key = nil
      end

      class InvoiceOperation < ApplicationRecord
        self.table_name = "invoice_operations"
      end

      # :reek:LongParameterList
      def self.call(route:, company_id:, generation:, actor:, params:, checkpoint:)
        new(route:, company_id:, generation:, actor:, params:, checkpoint:).call
      end

      # :reek:LongParameterList
      def initialize(route:, company_id:, generation:, actor:, params:, checkpoint:)
        @route = route.to_sym
        @company_id = company_id
        @generation = generation
        @actor = actor
        @body = params.fetch("body", nil) || {}
        @checkpoint = checkpoint
      end

      def call
        return Outcome.refusal(:invalid_request) unless valid_request?

        attempt
      rescue ReceiptTaken
        # A backstop: the operation and invoice locks normally stop two
        # writers from both reaching an insert. The failed attempt has rolled
        # back every row it wrote, so the steps run again, check the
        # generation first and then answer from what is stored now.
        attempt
      end

      private

        attr_reader :route, :company_id, :generation, :actor, :body, :checkpoint

        # Each attempt runs in its own savepoint, so a failure rolls back this
        # write even when the caller has a transaction open and rescues it.
        def attempt
          ApplicationRecord.transaction(requires_new: true) { run }
        end

        def run
          WriteSteps.lock_key(company_id, ACTOR_TYPE, actor.name, operation_id)
          WriteSteps.lock_key(company_id, INVOICE_LOCK, invoice_id)
          checkpoint.call(:operation_key_locked)
          stored_generation = WriteSteps.admitted_generation
          return Outcome.refusal(:stale_generation) unless WriteSteps.generation_matches?(generation, stored_generation)

          checkpoint.call(:generation_checked)
          stored = stored_answer
          checkpoint.call(:operation_checked)
          return stored if stored

          send(ROUTES.fetch(route), stored_generation)
        end

        # Request values

        def operation_id
          body["operation_id"]
        end

        def invoice_id
          body["invoice_id"]
        end

        def disposition
          body["disposition"]
        end

        def entry_ids
          body["entries"]
        end

        def valid_request?
          return false unless body.is_a?(Hash) && WriteSteps.id?(invoice_id) && UUID.match?(operation_id.to_s)
          return true unless route == :prepare

          # An entry listed twice is refused, as the service refuses it, so the
          # stored desired set a replay compares has one spelling per set.
          DISPOSITIONS.include?(disposition) && entry_ids.is_a?(Array) &&
            entry_ids.all? { |id| WriteSteps.id?(id) } && entry_ids.uniq.size == entry_ids.size
        end

        # Stored answers

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

        def find_operation
          InvoiceOperation.find_by(company_id:, actor_name: actor.name, operation_id:)
        end

        # A prepare replayed with another invoice, disposition or entry set is
        # a reused key, not a replay.
        def prepare_replay(operation)
          same = [operation.invoice_id, operation.disposition, operation.desired_entry_ids] ==
                 [invoice_id, disposition, entry_ids]
          same ? prepare_answer(operation) : Outcome.refusal(:idempotency_key_reused)
        end

        def find_receipt
          ServiceReceipt.find_by(company_id:, actor_name: actor.name, operation: route.to_s, key: operation_id)
        end

        def receipt_answer(receipt)
          return Outcome.refusal(:idempotency_key_reused) unless receipt.fingerprint == fingerprint

          Outcome.new(status: receipt.status, body: WriteSteps.replayed_body(receipt.body))
        end

        # Commit and abort act only on what prepare stored, so the invoice is
        # all a replay must repeat.
        def fingerprint
          Digest::SHA256.hexdigest(JSON.generate("invoice_id" => invoice_id))
        end

        # Routes

        def prepare(stored_generation)
          unresolved = unresolved_refusal
          return unresolved if unresolved

          entries = lock_entries(entry_ids)
          checkpoint.call(:rows_locked)
          kept_ids = entries.filter_map { |entry| entry.id if entry.discarded_at.nil? }
          decision = TimekeepingRules::ReservationDecision.call(
            current: decision_reservations(kept_ids, invoice_id), desired: entry_ids, disposition:,
            invoice_status: WIRE_INVOICE_STATUS
          )
          checkpoint.call(:decision_made)
          return conflict_refusal(decision[:conflicts]) unless decision[:conflicts].empty?

          operation = create_operation(stored_generation)
          reserve_provisionally(operation, decision[:reserve] + retained_by_this(operation))
          record_locked_flips(entries, stored_generation)
          prepare_answer(operation)
        end

        def commit(stored_generation)
          operation = find_operation
          return Outcome.refusal(:not_found) unless operation&.invoice_id == invoice_id
          return finish(TERMINAL_ANSWERS.fetch(:commit)) unless operation.state == PREPARED

          entries = lock_entries((own_provisional(operation) + invoice_committed(operation)).map(&:entry_id))
          checkpoint.call(:rows_locked)
          claimed_ids = own_provisional(operation).pluck(:entry_id)
          held_ids = invoice_committed(operation).pluck(:entry_id)
          # A claimed entry this invoice already held is kept, not newly reserved.
          reserved_ids = claimed_ids - held_ids
          released_ids = TimekeepingRules::ReservationDecision.call(
            current: decision_reservations(held_ids, operation.invoice_id), desired: operation.desired_entry_ids,
            disposition: operation.disposition, invoice_status: WIRE_INVOICE_STATUS
          )[:release]
          checkpoint.call(:decision_made)

          make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
          record_locked_flips(entries, stored_generation)
          operation.update!(state: COMMITTED, finished_at: Time.current)
          finish("reserved" => reserved_ids.size, "released" => released_ids.size)
        end

        def abort_operation(stored_generation)
          operation = find_operation
          return Outcome.refusal(:not_found) unless operation&.invoice_id == invoice_id
          return finish(TERMINAL_ANSWERS.fetch(:abort)) unless operation.state == PREPARED

          entries = lock_entries(own_provisional(operation).pluck(:entry_id))
          checkpoint.call(:rows_locked)
          # A claim on an entry this invoice still holds as its retained owner
          # gives nothing up, so it is not counted as dropped.
          kept = invoice_committed(operation).select(:entry_id)
          checkpoint.call(:decision_made)
          dropped = own_provisional(operation).where.not(entry_id: kept).delete_all
          own_provisional(operation).delete_all
          record_locked_flips(entries, stored_generation)
          operation.update!(state: ABORTED, finished_at: Time.current)
          finish("dropped" => dropped)
        end

        # Reservation changes

        def create_operation(stored_generation)
          InvoiceOperation.create!(
            company_id:, invoice_id:, operation_id:, actor_name: actor.name, state: PREPARED,
            desired_entry_ids: entry_ids, disposition:, generation: stored_generation, created_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique => error
          raise ReceiptTaken, error.message
        end

        # The desired entries this invoice already holds only as a retained
        # owner. A successor's prepare may take such an entry, so this
        # operation claims each one with a provisional row as well: whichever
        # operation prepares first holds the entry, and the other is refused
        # as provisional_elsewhere.
        def retained_by_this(operation)
          invoice_committed(operation).where(entry_id: entry_ids, disposition: RETAINED).pluck(:entry_id)
        end

        def reserve_provisionally(operation, reserved_ids)
          return if reserved_ids.empty?

          now = Time.current
          Reservation.insert_all!(reserved_ids.map do |entry_id|
            { company_id:, entry_id:, invoice_id: operation.invoice_id, state: PROVISIONAL,
              disposition: operation.disposition, operation_id: operation.operation_id,
              invoice_operation_id: operation.id, created_at: now }
          end)
        end

        # Order matters for the one-committed-per-entry index: a retained
        # committed row on an entry this operation claimed gives way first,
        # then the released rows go, then this operation's provisional rows
        # become committed, and every row the invoice holds takes the
        # operation's disposition.
        def make_desired_set_the_reservation_set(operation, claimed_ids, released_ids)
          Reservation.where(company_id:, entry_id: claimed_ids, state: COMMITTED, disposition: RETAINED).delete_all
          invoice_committed(operation).where(entry_id: released_ids).delete_all
          own_provisional(operation).update_all(state: COMMITTED)
          invoice_committed(operation).update_all(disposition: operation.disposition)
        end

        # Rows are selected by the owning operation's id, never by
        # operation_id alone, so another service's operation with the same id
        # is not touched.
        def own_provisional(operation)
          Reservation.where(company_id:, invoice_operation_id: operation.id, state: PROVISIONAL)
        end

        def invoice_committed(operation)
          Reservation.where(company_id:, invoice_id: operation.invoice_id, state: COMMITTED)
        end

        # The company's entries with these ids, discarded ones included, locked
        # in id order so two writers over the same entries wait in turn. The
        # flag is read in a second statement once the locks are held: a
        # statement that waited on a lock still reads reservations as they
        # were before the wait.
        def lock_entries(ids)
          locked_ids = LocalEntry.where(company_id:, id: ids.uniq).order(:id).lock("FOR UPDATE").pluck(:id)
          WriteSteps.reserved_rows(company_id, locked_ids).values_at(*locked_ids)
        end

        # Each entry's reservations in the form ReservationDecision reads, seen
        # from invoice_id. An id left out is one outside the company.
        def decision_reservations(ids, for_invoice_id)
          found = Reservation.where(company_id:, entry_id: ids).group_by(&:entry_id)
          ids.index_with do |entry_id|
            found.fetch(entry_id, []).map do |reservation|
              { invoice: reservation.invoice_id == for_invoice_id ? :this : :other, state: reservation.state,
                disposition: reservation.disposition }
            end
          end
        end

        # locked mirrors whether the entry has any reservation, so each entry
        # whose flag changed is an entry change: its version rises, and it gets
        # one audit row and one outbox snapshot. A change that keeps the flag,
        # such as provisional to committed, writes none of them.
        def record_locked_flips(entries, stored_generation)
          after = WriteSteps.reserved_rows(company_id, entries.map(&:id))
          flipped = entries.reject { |entry| after.fetch(entry.id).reserved == entry.reserved }
          checkpoint.call(:reservations_written)
          return if flipped.empty?

          flipped_ids = flipped.map(&:id)
          LocalEntry.where(company_id:, id: flipped_ids).update_all(["version = version + 1, updated_at = ?", Time.current])
          rows = WriteSteps.reserved_rows(company_id, flipped_ids)
          checkpoint.call(:entry_written)
          write_audit(flipped)
          checkpoint.call(:audit_written)
          WriteSteps.write_outbox(company_id:, rows: flipped_ids.map { |id| rows.fetch(id) }, generation: stored_generation)
          checkpoint.call(:outbox_written)
        end

        def write_audit(flipped)
          now = Time.current
          flipped.each do |entry|
            AuditRow.create!(
              company_id:, entry_id: entry.id, action: route.to_s, actor_type: ACTOR_TYPE, actor_id: nil,
              actor_name: actor.name, before: { "locked" => entry.reserved }, after: { "locked" => !entry.reserved },
              entry_created_at: entry.created_at, created_at: now
            )
          end
        end

        # Answers

        def prepare_answer(operation)
          entries = operation.desired_entry_ids.map { |entry_id| { "entry_id" => entry_id, "company_id" => company_id } }
          Outcome.success(200, "operation_id" => operation.operation_id, "state" => operation.state, "entries" => entries)
        end

        # Another operation still prepared for this invoice must be committed
        # or aborted first; the caller retries it by the id this names.
        def unresolved_refusal
          open = InvoiceOperation.find_by(company_id:, invoice_id:, state: PREPARED)
          return unless open

          Outcome.success(STATUS.fetch(:unresolved_operation),
                          "reason" => "unresolved_operation", "operation_id" => open.operation_id,
                          "retryable" => RESERVATIONS.dig("errors", "unresolved_operation", "retryable"))
        end

        def conflict_refusal(conflicts)
          body = conflicts.map { |conflict| { "entry_id" => conflict[:entry_id], "reason" => conflict[:reason].to_s } }
          Outcome.success(STATUS.fetch(:conflict), "reason" => "conflict", "conflicts" => body)
        end

        def finish(payload)
          outcome = Outcome.success(200, payload)
          store_receipt(outcome)
          checkpoint.call(:receipt_written)
          outcome
        end

        def store_receipt(outcome)
          ServiceReceipt.create!(
            company_id:, actor_name: actor.name, operation: route.to_s, key: operation_id, fingerprint:,
            status: outcome.status, body: WriteSteps.receipt_body(outcome.body), created_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique => error
          raise ReceiptTaken, error.message
        end
    end
  end
end

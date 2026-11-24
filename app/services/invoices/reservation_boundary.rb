# frozen_string_literal: true

module Invoices
  # Runs an invoice through the reservation port only when the invoice changes
  # which entries it holds, or is discarded or destroyed; never on every save
  # (docs/architecture/timekeeping-soa.md sections 7.2 and 9).
  #
  # Invoice, line item and line link callbacks call `register` before they
  # write. The first registration of an invoice in a transaction captures the
  # entries its lines reference at that moment. When the outermost joinable
  # transaction commits, before COMMIT is issued, each registered invoice is
  # flushed once: the decision table compares what the invoice holds with its
  # lines as they are now, and a change goes to the operation coordinator. An
  # error raised there rolls the whole transaction back.
  #
  # Re-saves inside the same transaction (totals syncs, nested line syncs)
  # only register an invoice that is already registered, so they never send
  # an operation of their own.
  module ReservationBoundary
    ACTIVE = ReservationDecision::ACTIVE

    module_function

    # added_entries: the entry ids of the line or link references the caller
    # is about to create, retarget or move onto the invoice. The flush checks
    # each one under the owner it reads, whatever else the invoice names.
    def register(invoice, added_entries: [])
      transaction = outermost_joinable_transaction(invoice.class.connection)
      raise OperationErrors::NoTransaction if transaction.nil?

      Registry.on(transaction).register(invoice, added_entries:)
    end

    # A destroyed invoice's row is gone when the flush runs, so its status is
    # read here, as the row stands just before the delete. The status kept
    # from an earlier save in the same transaction may be out of date.
    def register_destruction(invoice)
      register(invoice)
      transaction = outermost_joinable_transaction(invoice.class.connection)
      Registry.on(transaction).record_status(invoice.id, Invoice.where(id: invoice.id).pick(:status))
    end

    # What each billing answer leads to. Only `committed` returns; a state
    # not listed raises PrepareRetryable with the outcome's reason.
    MARK_BILLED_ROUTES = {
      "committed" => :billed,
      "refused" => OperationErrors::Refused
    }.freeze

    # The reason a billing is refused while the invoice's commit has not
    # reached the Timekeeping service yet.
    COMMIT_UNDELIVERED_REASON = "commit_undelivered"

    # Bills the invoice's entries. The monolith's adapters bill the entries
    # the invoice's lines reference, so an entry its holding still lists after
    # a line was removed stays reserved but is not billed. The Timekeeping
    # service's mark-billed route takes no entry list and bills every entry it
    # holds as committed for the invoice, held-only entries included. Every
    # answer but `committed` raises, so the caller's transaction rolls back the
    # sent status with it and the invoice is never sent with its entries left
    # unbilled.
    def mark_billed(invoice)
      holding = InvoiceEntryHolding.find_by(company_id: invoice.company_id, invoice_id: invoice.id)
      ownership = TimekeepingOwnership.current
      raise_while_commit_undelivered!(invoice, ownership)
      request = ReservationRequest.new(
        company_id: invoice.company_id,
        invoice_id: invoice.id,
        operation_id: SecureRandom.uuid,
        generation: ownership.generation,
        disposition: holding&.disposition || ACTIVE,
        entries: CompanyEntries.on_lines(invoice.id, invoice.company_id, source: EntryReferenceCheck.for(ownership))
      )
      outcome = ReservationAdapters.for(ownership).mark_billed(request)
      raise_unless_billed!(outcome)

      outcome
    end

    def raise_unless_billed!(outcome)
      route = MARK_BILLED_ROUTES.fetch(outcome.state, OperationErrors::PrepareRetryable)
      return if route == :billed
      raise route.new(outcome) if route == OperationErrors::Refused
      raise route.new(outcome.reason) if outcome.reason

      raise route
    end

    # The Timekeeping service bills only the reservations it holds as
    # committed, and answers success with nothing billed for any other. So
    # while a commit row of this invoice is undelivered, billing would let the
    # invoice be sent with its entries unbilled. The invoice's operation lock
    # keeps a save of the same invoice from adding a commit row meanwhile.
    def raise_while_commit_undelivered!(invoice, ownership)
      return unless Timekeeping::EntryOwner.for(ownership) == :timekeeping

      OperationLock.acquire!(ApplicationRecord.connection, company_id: invoice.company_id, invoice_id: invoice.id)
      undelivered = InvoiceOperationOutboxItem.where(
        company_id: invoice.company_id, invoice_id: invoice.id, kind: "commit", delivered_at: nil
      ).exists?
      raise OperationErrors::PrepareRetryable, COMMIT_UNDELIVERED_REASON if undelivered
    end

    # Commit callbacks fire only on the transaction whose parent is not
    # joinable (or that has no parent), so the registry lives there: nested
    # savepoints and joined transactions all register into it. Rails exposes
    # no public way to reach that transaction from a nested one, so the
    # connection's transaction stack is read directly.
    def outermost_joinable_transaction(connection)
      connection.transaction_manager.instance_variable_get(:@stack).reverse.take_while(&:joinable?).last
    end

    # The entries an invoice can hold are its own company's: an id that names
    # another company's entry is never sent across the reservation port.
    #
    # Where the monolith owns entries (the :projection source), an id the
    # company's timesheet_entries rows do not hold is dropped, so rows
    # written before validation refused such ids do not fail a save. Where
    # Timekeeping owns them (:prepare_response), those rows lag behind the
    # relay, so only an id they place under another company, or under no
    # company, is dropped; an id they do not hold yet is kept, and
    # Timekeeping's prepare answer decides whether it is the company's.
    module CompanyEntries
      module_function

      # Every entry id the invoice's direct and grouped lines name now, read
      # from the line rows alone. The invoice id pins the company.
      def referenced(invoice_id)
        direct = InvoiceLineItem.where(invoice_id:).where.not(timesheet_entry_id: nil).pluck(:timesheet_entry_id)
        grouped = InvoiceLineItemTimeEntry.joins(:invoice_line_item)
          .where(invoice_line_items: { invoice_id: }).pluck(:timesheet_entry_id)
        ReservationRequest.canonical_entries(direct + grouped)
      end

      # The entry ids an invoice's lines reference now that it can hold.
      def on_lines(invoice_id, company_id, source:)
        within(company_id, referenced(invoice_id), source:)
      end

      def within(company_id, entry_ids, source:)
        case source
        when :projection
          ReservationRequest.canonical_entries(TimesheetEntry.where(company_id:, id: entry_ids).pluck(:id))
        when :prepare_response
          misplaced = TimesheetEntry.where(id: entry_ids).where("company_id IS DISTINCT FROM ?", company_id).pluck(:id)
          ReservationRequest.canonical_entries(entry_ids - misplaced)
        else
          raise ArgumentError, "unknown entry reference source #{source.inspect}"
        end
      end
    end

    # What one invoice looked like at its first registration in a
    # transaction: every entry id its lines named then, unfiltered. The
    # status is kept for a destroyed invoice, whose row is gone when the flush
    # runs. added_entries collects the entry ids of every line or link
    # reference the transaction created, retargeted or moved onto the
    # invoice, so each is checked even when an older row names the same id.
    Registration = Data.define(:invoice_id, :company_id, :status, :referenced_entries, :added_entries) do
      def adding(entry_ids)
        with(added_entries: ReservationRequest.canonical_entries(added_entries + entry_ids))
      end
    end

    # The invoices one transaction changed. It is enrolled as a transaction
    # record, so Rails calls `before_committed!` before COMMIT and drops it on
    # commit or rollback; nothing outlives the transaction.
    class Registry
      def self.on(transaction)
        transaction.records&.find { |record| record.is_a?(self) } || new.tap { |registry| transaction.add_record(registry) }
      end

      def initialize
        @registrations = {}
        @flushing = false
      end

      # A new invoice is keyed by the record until its insert gives it an id;
      # it held nothing before, so its captured set is empty.
      def register(invoice, added_entries: [])
        return if @flushing

        if invoice.new_record?
          key = [:new, invoice.__id__]
          @registrations[key] = (@registrations[key] || registration_for(invoice, [])).adding(added_entries)
          return
        end

        pending = @registrations.delete([:new, invoice.__id__])&.with(invoice_id: invoice.id)
        current = @registrations[invoice.id]
        registration = current || pending || registration_for(invoice, CompanyEntries.referenced(invoice.id))
        registration = registration.adding(pending.added_entries) if current && pending
        @registrations[invoice.id] = registration.adding(added_entries)
      end

      def record_status(invoice_id, status)
        return if @flushing || status.nil?

        @registrations[invoice_id] = @registrations.fetch(invoice_id).with(status:)
      end

      def before_committed!
        @flushing = true
        Flush.new(@registrations.values.select(&:invoice_id)).call
      end

      def committed!(*, **) = nil
      def rolledback!(*, **) = nil
      def trigger_transactional_callbacks? = true

      private

        def registration_for(invoice, referenced_entries)
          Registration.new(
            invoice_id: invoice.id,
            company_id: invoice.company_id,
            status: invoice.status_in_database || invoice.status,
            referenced_entries:,
            added_entries: []
          )
        end
    end

    # Flushes every registered invoice of one transaction. All invoice locks
    # are taken first, in id order, so the facts each decision reads cannot
    # change under it. Holdings are seeded for every invoice before any
    # entry is checked: a sent invoice that loses a line to another invoice
    # claims that entry only through its captured set, so its holding must
    # exist when the receiving invoice is checked. Invoices that add entries
    # then go before those that only release, so a moved entry is never held
    # by neither invoice.
    class Flush
      def initialize(registrations)
        @registrations = registrations.sort_by(&:invoice_id)
      end

      def call
        connection = ApplicationRecord.connection
        @registrations.each do |registration|
          OperationLock.acquire!(connection, company_id: registration.company_id, invoice_id: registration.invoice_id)
        end

        changes = @registrations.map { |registration| InvoiceChange.read(registration) }
        changes.each(&:seed_holding)
        changes.sort_by.with_index { |change, index| [change.adds_entries? ? 0 : 1, index] }.each(&:apply)
      end
    end

    # One invoice's held set, lines and decision, read under its lock. The
    # owner is read here too: the billing fence holds the ownership row FOR
    # SHARE from the first billing write until commit, so it cannot change
    # before the flush ends.
    class InvoiceChange
      # The conflict reason for an entry that is missing or not the
      # invoice's company's (contracts/timekeeping/reservations.yml).
      NOT_FOUND = "not_found"

      def self.read(registration)
        company_id = registration.company_id
        invoice_id = registration.invoice_id
        ownership = TimekeepingOwnership.current
        source = EntryReferenceCheck.for(ownership)
        holding = InvoiceEntryHolding.find_by(company_id:, invoice_id:)
        referenced = CompanyEntries.referenced(invoice_id)
        new(
          registration:,
          invoice: Invoice.find_by(id: invoice_id),
          ownership:,
          entries: {
            referenced:,
            lines: CompanyEntries.within(company_id, referenced, source:),
            captured: CompanyEntries.within(company_id, registration.referenced_entries, source:)
          },
          holding: holding && {
            entries: CompanyEntries.within(company_id, holding.entry_ids, source:), disposition: holding.disposition
          }
        )
      end

      # entries: { referenced:, lines:, captured: }. referenced is every id
      # the lines name now; lines and captured are the ids the invoice can
      # hold now and at registration. holding: what the invoice's holding row
      # lists, or nil when it has none.
      def initialize(registration:, invoice:, ownership:, entries:, holding:)
        @registration = registration
        @invoice = invoice
        @ownership = ownership
        @referenced = entries.fetch(:referenced)
        @lines = entries.fetch(:lines)
        @captured = entries.fetch(:captured)
        @holding = holding
        @decision = ReservationDecision.call(
          status: status,
          discarded: invoice&.discarded? || false,
          destroyed: invoice.nil?,
          held:,
          lines: @lines
        )
      end

      def adds_entries?
        admitted_entries.any? || (@decision.present? && (@decision.fetch(:entries) - held.fetch(:entries)).any?)
      end

      # Records the held set of an invoice that has no holding yet (see
      # `held`), so a sent invoice keeps an entry after its line is removed,
      # and the adapter sees what an operation removes.
      def seed_holding
        return unless @holding.nil? && @captured.any? && (@decision || @lines != @captured)

        InvoiceEntryHolding.insert(
          { company_id: registration.company_id, invoice_id: registration.invoice_id,
            entry_ids: @captured, disposition: ACTIVE },
          unique_by: %i[company_id invoice_id]
        )
      end

      # Every id this transaction added to the lines is checked here, under
      # the owner the flush reads, whatever the invoice's status: refused
      # outright when the owner's own rows say it is not the company's, by
      # admit when the operation does not send it, and by the prepare answer
      # when it does.
      def apply
        refuse_not_found!(unholdable_entries) if unholdable_entries.any?
        admit if admitted_entries.any?
        send_operation if @decision
      rescue OperationErrors::Refused => refusal
        report_refusal(refusal)
        raise
      end

      private

        attr_reader :registration

        def status
          @invoice&.status || registration.status
        end

        # An invoice saved before holdings existed holds what its lines
        # referenced before this transaction changed them.
        def held
          @holding || { entries: @captured, disposition: ACTIVE }
        end

        # The ids of the references this transaction created, retargeted or
        # moved onto the invoice and that its lines still name, including an
        # id an older row also names or a deleted row used to name.
        def added_entries
          registration.added_entries & @referenced
        end

        # Added ids the invoice cannot hold, as CompanyEntries.within decides
        # for the owner read here. Under the projection source line
        # validation normally refuses them first, but it runs before the
        # ownership row is locked, so an owner change after it is caught
        # here. Under the prepare_response source these are ids the
        # projection already places under another company or none.
        def unholdable_entries
          added_entries - @lines
        end

        # The added ids that go through admit, which changes no locks but
        # applies the same conflict rules a draft's prepare does. Under the
        # projection source that is what a live sent invoice gains; line
        # validation checks every other save there. Under the prepare_response
        # source validation checks nothing, so it is every added id the
        # operation does not send to prepare, whatever the invoice's status.
        def admitted_entries
          return [] if @invoice.nil?
          return added_entries - (@decision || held).fetch(:entries) if source == :prepare_response
          return [] if @invoice.discarded? || status.to_s == ReservationDecision::DRAFT_STATUS

          @lines - @captured
        end

        def admit
          outcome = adapter.admit(request(entries: admitted_entries, disposition: ACTIVE))
          raise OperationErrors::Refused.new(outcome) if outcome.state == "refused"
        end

        def refuse_not_found!(entry_ids)
          conflicts = entry_ids.map { |entry_id| { entry_id:, reason: NOT_FOUND } }
          raise OperationErrors::Refused.new(ReservationOutcome.new(state: "refused", conflicts:, counts: {}))
        end

        def send_operation
          operation = request(entries: @decision.fetch(:entries), disposition: @decision.fetch(:disposition))
          OperationCoordinator.new(reservations: adapter)
            .call(operation, holding: { entry_ids: operation.entries, disposition: operation.disposition })
        end

        # Reported here, in the save that was refused, and not by the adapter,
        # whose abort the outbox worker and the recovery sweep can deliver
        # again.
        def report_refusal(refusal)
          ReservationRefused.notify(
            company_id: registration.company_id,
            invoice_id: registration.invoice_id,
            reason: refusal.outcome&.conflicts&.first&.fetch(:reason)
          )
        end

        def request(entries:, disposition:)
          ReservationRequest.new(
            company_id: registration.company_id,
            invoice_id: registration.invoice_id,
            operation_id: SecureRandom.uuid,
            generation: ownership.generation,
            disposition:,
            entries:
          )
        end

        attr_reader :ownership

        def source
          EntryReferenceCheck.for(ownership)
        end

        def adapter
          @adapter ||= ReservationAdapters.for(ownership)
        end
    end

    private_constant :CompanyEntries, :Registration, :Registry, :Flush, :InvoiceChange
  end
end

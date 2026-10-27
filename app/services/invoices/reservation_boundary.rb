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

    def register(invoice)
      transaction = outermost_joinable_transaction(invoice.class.connection)
      raise OperationErrors::NoTransaction if transaction.nil?

      Registry.on(transaction).register(invoice)
    end

    # A destroyed invoice's row is gone when the flush runs, so its status is
    # read here, as the row stands just before the delete. The status kept
    # from an earlier save in the same transaction may be out of date.
    def register_destruction(invoice)
      register(invoice)
      transaction = outermost_joinable_transaction(invoice.class.connection)
      Registry.on(transaction).record_status(invoice.id, Invoice.where(id: invoice.id).pick(:status))
    end

    # Bills the entries the invoice's lines reference. An entry its holding
    # still lists after a line was removed stays reserved, but it is no longer
    # on the invoice, so it is not billed. A refused billing raises, so the
    # caller's transaction rolls back the sent status with it and the invoice
    # is never sent with its entries left unbilled.
    def mark_billed(invoice)
      holding = InvoiceEntryHolding.find_by(company_id: invoice.company_id, invoice_id: invoice.id)
      ownership = TimekeepingOwnership.current
      request = ReservationRequest.new(
        company_id: invoice.company_id,
        invoice_id: invoice.id,
        operation_id: SecureRandom.uuid,
        generation: ownership.generation,
        disposition: holding&.disposition || ACTIVE,
        entries: CompanyEntries.on_lines(invoice.id, invoice.company_id)
      )
      outcome = ReservationAdapters.for(ownership).mark_billed(request)
      raise OperationErrors::Refused.new(outcome) if outcome.state == "refused"

      outcome
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
    # Validation already refuses such ids on new lines; this keeps rows
    # written before it from failing a save.
    module CompanyEntries
      module_function

      # The entry ids an invoice's direct and grouped lines reference now.
      def on_lines(invoice_id, company_id)
        direct = InvoiceLineItem.joins(:timesheet_entry)
          .where(invoice_id:, timesheet_entries: { company_id: }).pluck(:timesheet_entry_id)
        grouped = InvoiceLineItemTimeEntry.joins(:invoice_line_item, :timesheet_entry)
          .where(invoice_line_items: { invoice_id: }, timesheet_entries: { company_id: }).pluck(:timesheet_entry_id)
        ReservationRequest.canonical_entries(direct + grouped)
      end

      def within(company_id, entry_ids)
        ReservationRequest.canonical_entries(TimesheetEntry.where(company_id:, id: entry_ids).pluck(:id))
      end
    end

    # What one invoice looked like at its first registration in a
    # transaction. The status is kept for a destroyed invoice, whose row is
    # gone when the flush runs.
    Registration = Data.define(:invoice_id, :company_id, :status, :captured_entries)

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
      def register(invoice)
        return if @flushing

        if invoice.new_record?
          @registrations[[:new, invoice.__id__]] ||= registration_for(invoice, [])
          return
        end

        pending = @registrations.delete([:new, invoice.__id__])
        @registrations[invoice.id] ||= pending&.with(invoice_id: invoice.id) ||
          registration_for(invoice, CompanyEntries.on_lines(invoice.id, invoice.company_id))
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

        def registration_for(invoice, captured_entries)
          Registration.new(
            invoice_id: invoice.id,
            company_id: invoice.company_id,
            status: invoice.status_in_database || invoice.status,
            captured_entries:
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

    # One invoice's held set, lines and decision, read under its lock.
    class InvoiceChange
      def self.read(registration)
        company_id = registration.company_id
        invoice_id = registration.invoice_id
        holding = InvoiceEntryHolding.find_by(company_id:, invoice_id:)
        new(
          registration:,
          invoice: Invoice.find_by(id: invoice_id),
          lines: CompanyEntries.on_lines(invoice_id, company_id),
          holding: holding && { entries: CompanyEntries.within(company_id, holding.entry_ids), disposition: holding.disposition }
        )
      end

      # holding: what the invoice's holding row lists, or nil when it has none.
      def initialize(registration:, invoice:, lines:, holding:)
        @registration = registration
        @invoice = invoice
        @lines = lines
        @holding = holding
        @decision = ReservationDecision.call(
          status: status,
          discarded: invoice&.discarded? || false,
          destroyed: invoice.nil?,
          held:,
          lines:
        )
      end

      def adds_entries?
        admitted_entries.any? || (@decision.present? && (@decision.fetch(:entries) - held.fetch(:entries)).any?)
      end

      # Records the held set of an invoice that has no holding yet (see
      # `held`), so a sent invoice keeps an entry after its line is removed,
      # and the adapter sees what an operation removes.
      def seed_holding
        return unless @holding.nil? && registration.captured_entries.any? &&
          (@decision || @lines != registration.captured_entries)

        InvoiceEntryHolding.insert(
          { company_id: registration.company_id, invoice_id: registration.invoice_id,
            entry_ids: registration.captured_entries, disposition: ACTIVE },
          unique_by: %i[company_id invoice_id]
        )
      end

      def apply
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
          @holding || { entries: registration.captured_entries, disposition: ACTIVE }
        end

        # A live sent invoice changes no locks, but the entries its lines
        # gain must still pass the same conflict rules a draft's do.
        def admitted_entries
          return [] if @invoice.nil? || @invoice.discarded? || status.to_s == ReservationDecision::DRAFT_STATUS

          @lines - registration.captured_entries
        end

        def admit
          outcome = adapter.admit(request(entries: admitted_entries, disposition: ACTIVE))
          raise OperationErrors::Refused.new(outcome) if outcome.state == "refused"
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

        def ownership
          @ownership ||= TimekeepingOwnership.current
        end

        def adapter
          @adapter ||= ReservationAdapters.for(ownership)
        end
    end

    private_constant :CompanyEntries, :Registration, :Registry, :Flush, :InvoiceChange
  end
end

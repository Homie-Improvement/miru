# frozen_string_literal: true

require "rails_helper"

# Live proofs of the failure cases in docs/architecture/timekeeping-soa.md,
# section 9.3. Each example name starts with the exact Case text of its row.
#
# Every example boots the whole demo runtime, starts from the "legacy" owner
# state and runs a real cutover, because the "timekeeping" owner state does not
# copy the seed into the Timekeeping database. A boot and a cutover cost
# minutes, so each row is one example that loops over both seeded companies;
# every expectation message names the company, so a failure for one company is
# never hidden by the other.
#
# The seed bills every entry it puts on an invoice, and the edit policy refuses
# billed entries whatever their reservation. So each example has one of the
# company's employees create fresh, unbilled entries after cutover, and a
# refused edit can only come from the reservation lock.
#
# Invoices are saved in this process against the shared monolith database;
# Timekeeping is reached over HTTP. Faults are injected by wrapping product
# objects from the test side only. Reservations are read from Timekeeping's own
# database, never from the stored entries.locked column.
RSpec.describe "Timekeeping section 9.3 failure cases", :integrated_runtime, :two_tenant_seed,
  committed_data: true, owner_state: "legacy", type: :request do
  # Raised by the test-side wrapper that fails the invoice commit after a
  # `prepared` answer.
  let(:section_9_3_forced_commit_failure) { Class.new(StandardError) }

  def section_9_3_companies
    { "Fork & Leaf Salads" => fork_and_leaf, "Copper Kettle Bakery" => copper_kettle }
  end

  # Runs the block for each company. aggregate_failures collects only failed
  # expectations, so a poll that times out for one company is recorded as a
  # failed expectation here; otherwise its error would skip the next company.
  def section_9_3_each_company
    section_9_3_companies.each do |name, company|
      yield name, company
    rescue TimekeepingSection93Live::PollTimeout => timeout
      expect(timeout).to be_nil, "#{name}: #{timeout.message}"
    end
  end

  # The first employee of the company who is a member of one of its billable
  # projects, with that project. Seeded employees can create entries on it.
  def section_9_3_employee_and_project(company)
    billable_projects = company.projects.kept.where(billable: true)
    company.users.with_role(:employee, company).order(:id).each do |user|
      project = billable_projects.joins(:project_members).where(project_members: { user_id: user.id }).order(:id).first
      return [user, project] if project
    end
    raise ArgumentError, "#{company.name} has no employee on a billable project"
  end

  # Creates an unbilled entry dated today as the employee, through the
  # timesheet entry API, which forwards the write to Timekeeping after
  # cutover. Waits until the projection row exists, because invoice lines
  # reference timesheet_entries.
  def section_9_3_fresh_entry(company:, employee:, project:, note:)
    sign_in employee
    send_request :post, api_v1_timesheet_entry_index_path, params: {
      project_id: project.id, user_id: employee.id,
      timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note:, bill_status: :unbilled }
    }, headers: auth_headers(employee)
    expect(response).to be_successful, "#{company.name}: creating #{note.inspect} answered #{response.status}"
    entry_id = json_response.fetch("entry").fetch("id")

    section_9_3_poll_until("#{company.name}: projection row for entry #{entry_id}") do
      TimesheetEntry.uncached { TimesheetEntry.unscoped.exists?(id: entry_id) }
    end
    TimesheetEntry.unscoped.find(entry_id)
  end

  def section_9_3_line(entry)
    { name: "Section 9.3 work", date: Date.current, rate: 100, quantity: 60, timesheet_entry_id: entry.id }
  end

  def section_9_3_draft_holding(company:, project:, entries:)
    create(:invoice, company:, client: project.client, invoice_line_items_attributes: entries.map { |entry| section_9_3_line(entry) })
  end

  def section_9_3_reservations(company, entries)
    section_9_3_timekeeping_reservations(company_id: company.id, entry_ids: entries.map(&:id))
  end

  def section_9_3_latest_intent(company, invoice)
    InvoiceOperationIntent.uncached do
      InvoiceOperationIntent.where(company_id: company.id, invoice_id: invoice.id).order(:created_at).last
    end
  end

  # The Timekeeping state of one invoice operation, or nil when Timekeeping
  # never stored it.
  def section_9_3_operation_state(company, invoice, operation_id)
    section_9_3_timekeeping_operations(company_id: company.id, invoice_id: invoice.id)
      .find { |operation| operation.fetch(:operation_id) == operation_id.to_s }&.fetch(:state)
  end

  # Waits until Timekeeping stores the failed save's operation as aborted and
  # answers that state; the poll raises when the deadline passes first.
  def section_9_3_await_abort(name, company, invoice, intent)
    section_9_3_poll_until("#{name}: abort of operation #{intent.operation_id}",
                           satisfied: ->(observed) { observed == "aborted" }) do
      section_9_3_operation_state(company, invoice, intent.operation_id)
    end
  end

  # The employee tries to change the note of an entry they own. Answers the
  # response status.
  def section_9_3_employee_edit_status(employee:, project:, entry:)
    sign_in employee
    send_request :patch, api_v1_timesheet_entry_path(entry.id), params: {
      project_id: project.id,
      timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Edited after the failed save" }
    }, headers: auth_headers(employee)
    response.status
  end

  # Makes the invoice transaction fail after Timekeeping answered `prepared`,
  # so the product's own rollback path records the failure and sends abort.
  def section_9_3_fail_commit_after_prepare!
    allow_any_instance_of(Invoices::OperationCoordinator).to receive(:call).and_wrap_original do |original, *args, **kwargs|
      outcome = original.call(*args, **kwargs)
      raise section_9_3_forced_commit_failure, "commit forced to fail after #{outcome.state}" if outcome.state == "prepared"

      outcome
    end
  end

  def section_9_3_restore_commit!
    allow_any_instance_of(Invoices::OperationCoordinator).to receive(:call).and_call_original
  end

  # A reservation client whose first prepare answer is thrown away after
  # Timekeeping applied it, as after a timeout. Later prepares, including the
  # replays the abort sends, get their answers.
  def section_9_3_client_dropping_first_prepare
    dropped = false
    drop = lambda do |_method, path|
      next false if dropped || !path.end_with?("/reservations/prepare")

      dropped = true
    end
    Timekeeping::ReservationClient.new(
      http: TimekeepingContract::DroppingHttp.new(Timekeeping::ReservationHttp.new, drop:)
    )
  end

  def section_9_3_committed_by(reservations, entry, invoice)
    reservations.select do |reservation|
      reservation.fetch(:entry_id) == entry.id && reservation.fetch(:state) == "committed" &&
        reservation.fetch(:invoice_id) == invoice.id
    end
  end

  # Sets a draft that holds its entries to sent without the send flow. A live
  # non-draft sends no reservation operation, so its entries stay committed to
  # it and stay unbilled.
  def section_9_3_non_draft_holding(company:, project:, entries:)
    section_9_3_draft_holding(company:, project:, entries:).tap { |invoice| invoice.update!(status: :sent) }
  end

  # Prepares the entries for a new draft directly against Timekeeping, the way
  # an invoice save starts, and answers the client and its request.
  def section_9_3_successor_prepare(company:, invoice:, entries:)
    request = Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: Invoices::ReservationDecision::ACTIVE,
      entries: entries.map(&:id)
    )
    client = Timekeeping::ReservationClient.new(http: Timekeeping::ReservationHttp.new)
    [client, request, client.prepare(request)]
  end

  # The entry as the employee reads it from Timekeeping, whose `locked` is true
  # exactly when the entry has a reservation.
  def section_9_3_entry_locked(company:, employee:, entry:)
    Timekeeping::EntryApiClient.new
      .show_entry(company_id: company.id, entry_id: entry.id, acting_user_id: employee.id, request_id: SecureRandom.uuid)
      .fetch("locked")
  end

  # Every stored column of the invoice, read fresh; nil once the row is gone.
  def section_9_3_stored_invoice(invoice)
    Invoice.uncached { Invoice.unscoped.find_by(id: invoice.id)&.attributes }
  end

  # Every stored column of the invoice's line items, read fresh, in id order.
  def section_9_3_stored_lines(invoice)
    InvoiceLineItem.uncached { InvoiceLineItem.where(invoice_id: invoice.id).order(:id).map(&:attributes) }
  end

  # The monolith's operation ledger for one invoice (intents, holding and
  # outbox rows), which has no foreign key to invoices so a hard delete keeps it.
  def section_9_3_monolith_ledger(company, invoice)
    scope = { company_id: company.id, invoice_id: invoice.id }
    InvoiceOperationIntent.uncached do
      {
        intents: InvoiceOperationIntent.where(scope).order(:created_at, :id)
          .pluck(:operation_id, :state, :disposition, :desired_entry_ids),
        holding: InvoiceEntryHolding.where(scope).pick(:entry_ids, :disposition),
        outbox: InvoiceOperationOutboxItem.where(scope).order(:id).pluck(:operation_id, :kind)
      }
    end
  end

  def section_9_3_bulk_delete(company, invoice)
    owner = company.users.with_role(:owner, company).order(:id).first!
    sign_in owner
    send_request :post, api_v1_invoices_bulk_deletion_index_path, params: { invoices_ids: [invoice.id] },
      headers: auth_headers(owner)
    response
  end

  # The adapter, with the given block called on every prepare outcome before
  # the save sees it. The block runs inside the invoice transaction, which
  # holds the invoice-identity lock by then.
  def section_9_3_after_prepare(adapter, &on_outcome)
    SimpleDelegator.new(adapter).tap do |wrapped|
      wrapped.define_singleton_method(:prepare) do |request|
        __getobj__.prepare(request).tap(&on_outcome)
      end
    end
  end

  # Parks, after its prepare answered, only a save that runs on a thread marked
  # by section_9_3_mark_save_to_park. The answer's state is pushed to parked,
  # then the save waits for release. Every other caller of the adapter,
  # recovery's abort delivery included, gets the real adapter.
  def section_9_3_park_marked_saves!(parked:, release:)
    allow(Invoices::ReservationAdapters).to receive(:for).and_wrap_original do |original, *args|
      adapter = original.call(*args)
      next adapter unless Thread.current[:section_9_3_park_after_prepare]

      section_9_3_after_prepare(adapter) do |outcome|
        parked << outcome.state
        release.pop
      end
    end
  end

  def section_9_3_mark_save_to_park
    Thread.current[:section_9_3_park_after_prepare] = true
  end

  def section_9_3_restore_adapters!
    allow(Invoices::ReservationAdapters).to receive(:for).and_call_original
  end

  # Points one existing line at another entry, keeping its rate and quantity,
  # so the invoice's totals and its own row stay as they were.
  def section_9_3_repoint_line(invoice, line, entry)
    Invoice.find(invoice.id).update!(invoice_line_items_attributes: [{ id: line.id, timesheet_entry_id: entry.id }])
  end

  # A new operation of the invoice that prepares only the entry.
  def section_9_3_prepare_request(company:, invoice:, entry:)
    Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: Invoices::ReservationDecision::ACTIVE,
      entries: [entry.id]
    )
  end

  # Sends one prepare through the product's reservation client and pushes the
  # raw Timekeeping answer to answers, so the example can read its HTTP
  # status, which the client maps away. Uses no database connection.
  def section_9_3_recorded_prepare(request, answers:)
    http = Timekeeping::ReservationHttp.new
    recorder = lambda do |method, path, headers:, body:|
      http.call(method, path, headers:, body:).tap { |answer| answers << answer }
    end
    Timekeeping::ReservationClient.new(http: recorder).prepare(request)
  end

  def section_9_3_drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  # What recovery could change for one invoice: its intents, its outbox rows
  # and Timekeeping's reservations on the given entries.
  def section_9_3_recovery_snapshot(company, invoice, entries)
    scope = { company_id: company.id, invoice_id: invoice.id }
    InvoiceOperationIntent.uncached do
      {
        intents: InvoiceOperationIntent.where(scope).order(:created_at, :id).pluck(:operation_id, :state),
        outbox: InvoiceOperationOutboxItem.where(scope).order(:id).pluck(:id, :kind, :delivered_at),
        reservations: section_9_3_reservations(company, entries)
      }
    end
  end

  def section_9_3_recover_now
    RecoverInvoiceOperationIntentsJob.perform_now(pickup_age: 0.seconds)
  end

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  it "Prepare answer lost (timeout or 5xx): the save fails, the intent is failed, and after abort each entry's " \
     "reservation equals its state before the save" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          held = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the draft")
          added = section_9_3_fresh_entry(company:, employee:, project:, note: "Added by the lost save")
          draft = section_9_3_draft_holding(company:, project:, entries: [held])
          baseline = section_9_3_reservations(company, [held, added])
          expect(section_9_3_committed_by(baseline, held, draft).size).to eq(1),
            "#{name}: the draft should hold its entry committed before the save; saw #{baseline.inspect}"

          allow(Invoices::ReservationAdapters).to receive(:for).and_return(section_9_3_client_dropping_first_prepare)
          expect { draft.reload.update!(invoice_line_items_attributes: [section_9_3_line(added)]) }
            .to raise_error(Invoices::OperationErrors::PrepareRetryable), "#{name}: the save should fail"
          allow(Invoices::ReservationAdapters).to receive(:for).and_call_original

          intent = section_9_3_latest_intent(company, draft)
          expect(intent&.state).to eq("failed"), "#{name}: the failed save's intent is #{intent&.state.inspect}"
          if intent
            state = section_9_3_await_abort(name, company, draft, intent)
            expect(state).to eq("aborted"), "#{name}: the lost save's operation is #{state.inspect}"
          end
          after = section_9_3_reservations(company, [held, added])
          expect(after).to eq(baseline),
            "#{name}: reservations after abort #{after.inspect} differ from before the save #{baseline.inspect}"
          expect(draft.reload.invoice_line_items.pluck(:timesheet_entry_id)).to eq([held.id]),
            "#{name}: the invoice change should not be made"
        end
      end
    end
  end

  it "Database commit fails after a 200 prepare: the intent is failed, the added entry ends free and the removed " \
     "entry stays reserved by the draft" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          removed = section_9_3_fresh_entry(company:, employee:, project:, note: "Removed by the failed save")
          added = section_9_3_fresh_entry(company:, employee:, project:, note: "Added by the failed save")
          draft = section_9_3_draft_holding(company:, project:, entries: [removed])
          baseline = section_9_3_reservations(company, [removed, added])
          expect(section_9_3_committed_by(baseline, removed, draft).size).to eq(1),
            "#{name}: the draft should hold the entry to remove before the save; saw #{baseline.inspect}"

          removed_line = draft.invoice_line_items.find_by!(timesheet_entry_id: removed.id)
          section_9_3_fail_commit_after_prepare!
          expect do
            draft.reload.update!(invoice_line_items_attributes: [{ id: removed_line.id, _destroy: true }, section_9_3_line(added)])
          end.to raise_error(section_9_3_forced_commit_failure), "#{name}: the commit should fail"
          section_9_3_restore_commit!

          intent = section_9_3_latest_intent(company, draft)
          expect(intent&.state).to eq("failed"), "#{name}: the failed save's intent is #{intent&.state.inspect}"
          if intent
            state = section_9_3_await_abort(name, company, draft, intent)
            expect(state).to eq("aborted"), "#{name}: the failed save's operation is #{state.inspect}"
          end
          after = section_9_3_reservations(company, [removed, added])
          expect(after.select { |reservation| reservation.fetch(:entry_id) == added.id }).to eq([]),
            "#{name}: the added entry should end free; saw #{after.inspect}"
          expect(after).to eq(baseline),
            "#{name}: the removed entry should stay reserved by the draft as before; saw #{after.inspect}"
        end
      end
    end
  end

  it "Saved draft fails a save that removes an entry: the entry stays reserved by the draft and locked" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the saved draft")
          draft = section_9_3_draft_holding(company:, project:, entries: [entry])
          baseline = section_9_3_reservations(company, [entry])
          expect(section_9_3_committed_by(baseline, entry, draft).size).to eq(1),
            "#{name}: the draft should hold its entry committed before the save; saw #{baseline.inspect}"

          line = draft.invoice_line_items.find_by!(timesheet_entry_id: entry.id)
          section_9_3_fail_commit_after_prepare!
          expect { draft.reload.update!(invoice_line_items_attributes: [{ id: line.id, _destroy: true }]) }
            .to raise_error(section_9_3_forced_commit_failure), "#{name}: the commit should fail"
          section_9_3_restore_commit!

          intent = section_9_3_latest_intent(company, draft)
          expect(intent&.state).to eq("failed"), "#{name}: the failed save's intent is #{intent&.state.inspect}"
          if intent
            state = section_9_3_await_abort(name, company, draft, intent)
            expect(state).to eq("aborted"), "#{name}: the failed save's operation is #{state.inspect}"
          end
          after = section_9_3_reservations(company, [entry])
          expect(section_9_3_committed_by(after, entry, draft).size).to eq(1),
            "#{name}: the entry should still be reserved by the committed draft; saw #{after.inspect}"
          expect(section_9_3_entry_locked(company:, employee:, entry:)).to be(true),
            "#{name}: the entry should still show locked: true after the failed save"
          status = section_9_3_employee_edit_status(employee:, project:, entry:)
          expect(status).to be_between(400, 499),
            "#{name}: an employee edit of the still-reserved entry answered #{status}, not a refusal"
        end
      end
    end
  end

  it "Successor prepares an entry held by a discarded or destroyed non-draft, then aborts: the entry stays " \
     "reserved retained by the old invoice and locked against edits" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the discarded invoice")
          old_invoice = section_9_3_non_draft_holding(company:, project:, entries: [entry])
          old_invoice.discard!
          retained = section_9_3_reservations(company, [entry])
          expect(retained.map { |row| row.values_at(:state, :disposition, :invoice_id) })
            .to eq([["committed", "retained", old_invoice.id]]),
              "#{name}: the discarded non-draft should keep its entry retained; saw #{retained.inspect}"

          successor = create(:invoice, company:, client: project.client)
          client, request, prepared = section_9_3_successor_prepare(company:, invoice: successor, entries: [entry])
          expect(prepared.state).to eq("prepared"), "#{name}: the successor's prepare answered #{prepared.state}"
          aborted = client.abort(request)
          expect(aborted.state).to eq("aborted"), "#{name}: the successor's abort answered #{aborted.state}"

          after = section_9_3_reservations(company, [entry])
          expect(after).to eq(retained),
            "#{name}: after the abort the entry should hold only the old retained reservation; saw #{after.inspect}"
          status = section_9_3_employee_edit_status(employee:, project:, entry:)
          expect(status).to be_between(400, 499),
            "#{name}: an employee edit of the retained entry answered #{status}, not a refusal"
        end
      end
    end
  end

  it "Successor commits an entry held `retained`: the entry is reserved by the successor only" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "Moved to the successor")
          old_invoice = section_9_3_non_draft_holding(company:, project:, entries: [entry])
          old_invoice.discard!
          retained = section_9_3_reservations(company, [entry])
          expect(retained.map { |row| row.values_at(:state, :disposition, :invoice_id) })
            .to eq([["committed", "retained", old_invoice.id]]),
              "#{name}: the discarded non-draft should keep its entry retained; saw #{retained.inspect}"

          successor = section_9_3_draft_holding(company:, project:, entries: [entry])

          after = section_9_3_reservations(company, [entry])
          expect(after.map { |row| row.values_at(:state, :disposition, :invoice_id) })
            .to eq([["committed", "active", successor.id]]),
              "#{name}: the entry should be reserved by the successor only; saw #{after.inspect}"
        end
      end
    end
  end

  it "Draft discarded: the draft's reservations are released, the entry shows locked: false and an employee " \
     "can edit it" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the discarded draft")
          draft = section_9_3_draft_holding(company:, project:, entries: [entry])
          held = section_9_3_reservations(company, [entry])
          expect(section_9_3_committed_by(held, entry, draft).size).to eq(1),
            "#{name}: the draft should hold its entry committed before the discard; saw #{held.inspect}"
          expect(section_9_3_entry_locked(company:, employee:, entry:)).to be(true),
            "#{name}: the held entry should show locked: true before the discard"

          draft.discard!

          after = section_9_3_reservations(company, [entry])
          expect(after).to eq([]), "#{name}: the discarded draft should release its entry; saw #{after.inspect}"
          expect(section_9_3_entry_locked(company:, employee:, entry:)).to be(false),
            "#{name}: the released entry should show locked: false"
          status = section_9_3_employee_edit_status(employee:, project:, entry:)
          expect(status).to eq(200), "#{name}: an employee edit of the released entry answered #{status}"
        end
      end
    end
  end

  it "Hard delete of a non-draft fails (payments): the invoice, its line items and the reservations stay as before" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "On the paid invoice")
          invoice = section_9_3_non_draft_holding(company:, project:, entries: [entry])
          create(:payment, invoice:, amount: 10)
          invoice_before = section_9_3_stored_invoice(invoice)
          lines_before = section_9_3_stored_lines(invoice)
          baseline = section_9_3_reservations(company, [entry])
          expect(section_9_3_committed_by(baseline, entry, invoice).size).to eq(1),
            "#{name}: the non-draft should hold its entry committed before the delete; saw #{baseline.inspect}"

          answer = section_9_3_bulk_delete(company, invoice)

          expect(answer.status).to eq(422), "#{name}: the bulk delete answered #{answer.status}"
          expect(JSON.parse(answer.body).fetch("undeletable_invoice_ids")).to eq([invoice.id]),
            "#{name}: the refusal should name the paid invoice"
          expect(section_9_3_stored_invoice(invoice)).to eq(invoice_before),
            "#{name}: the paid invoice's stored row should be unchanged"
          expect(section_9_3_stored_lines(invoice)).to eq(lines_before),
            "#{name}: the paid invoice's stored line items should be unchanged"
          after = section_9_3_reservations(company, [entry])
          expect(after).to eq(baseline),
            "#{name}: reservations after the refused delete #{after.inspect} differ from before #{baseline.inspect}"
        end
      end
    end
  end

  it "Hard delete of a non-draft succeeds: the entry stays reserved retained with its tenant, invoice and " \
     "disposition, the operation ledger is kept, and a new invoice can prepare and commit it" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "On the deleted invoice")
          invoice = section_9_3_non_draft_holding(company:, project:, entries: [entry])

          answer = section_9_3_bulk_delete(company, invoice)

          expect(answer.status).to eq(204), "#{name}: the bulk delete answered #{answer.status}"
          expect(Invoice.unscoped.exists?(id: invoice.id)).to be(false), "#{name}: the invoice should be deleted"
          retained = section_9_3_reservations(company, [entry])
          expect(retained.map { |row| row.values_at(:company_id, :entry_id, :state, :disposition, :invoice_id) })
            .to eq([[company.id, entry.id, "committed", "retained", invoice.id]]),
              "#{name}: the deleted invoice's entry should stay reserved retained; saw #{retained.inspect}"
          operations = section_9_3_timekeeping_operations(company_id: company.id, invoice_id: invoice.id)
          # The ledger keeps both operations of the deleted invoice: the draft
          # save that reserved the entry, and the delete that retained it.
          expect(operations.map { |operation| operation.values_at(:state, :disposition) })
            .to eq([%w[committed active], %w[committed retained]]),
              "#{name}: the deleted invoice's operations should stay in the ledger; saw #{operations.inspect}"
          expect(operations.map { |operation| operation.fetch(:operation_id) })
            .to include(retained.first&.fetch(:operation_id)),
              "#{name}: the retained reservation should name an operation the ledger kept; saw #{operations.inspect}"
          ledger = section_9_3_monolith_ledger(company, invoice)
          expect(ledger[:intents].map { |intent| intent.drop(1) })
            .to eq([["committed", "active", [entry.id]], ["committed", "retained", [entry.id]]]),
              "#{name}: the deleted invoice's intents should stay in the monolith ledger; saw #{ledger.inspect}"
          expect(ledger[:intents].map(&:first).map(&:to_s)).to eq(operations.map { |operation| operation.fetch(:operation_id) }),
            "#{name}: the monolith intents and Timekeeping operations should name the same operations; saw #{ledger.inspect}"
          expect(ledger[:holding]).to eq([[entry.id], "retained"]),
            "#{name}: the deleted invoice's holding should stay, retained; saw #{ledger.inspect}"
          expect(ledger[:outbox]).to eq(ledger[:intents].map { |intent| [intent.first, "commit"] }),
            "#{name}: each kept intent should keep its commit outbox row; saw #{ledger.inspect}"
          status = section_9_3_employee_edit_status(employee:, project:, entry:)
          expect(status).to be_between(400, 499),
            "#{name}: an employee edit of the retained entry answered #{status}, not a refusal"

          successor = section_9_3_draft_holding(company:, project:, entries: [entry])

          after = section_9_3_reservations(company, [entry])
          expect(after.map { |row| row.values_at(:state, :disposition, :invoice_id) })
            .to eq([["committed", "active", successor.id]]),
              "#{name}: a new invoice should prepare and commit the entry; saw #{after.inspect}"
        end
      end
    end
  end

  # The test holds the entry row first, so both prepares are sure to arrive
  # while it is locked; without the hold they could run one after the other
  # and pass with Timekeeping's entry lock removed. The proof that they
  # serialize on the entry row is that both wait on the held row.
  it "Two invoices prepare one entry at once: both prepares wait on the entry row, then exactly one gets 200 and " \
     "the other 409 provisional_elsewhere" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "Prepared by two invoices at once")
          invoices = Array.new(2) { create(:invoice, company:, client: project.client) }
          holder_pids = Queue.new
          release = Queue.new
          answers = Queue.new
          prepares = []
          hold = committed_data_thread do
            section_9_3_hold_timekeeping_entry(company_id: company.id, entry_id: entry.id, holder_pids:, release:)
          end
          begin
            holder_pid = holder_pids.pop(timeout: 10)
            expect(holder_pid).not_to be_nil, "#{name}: the test could not hold entry #{entry.id} on Timekeeping"
            requests = invoices.map { |invoice| section_9_3_prepare_request(company:, invoice:, entry:) }
            # Plain threads: a prepare is one HTTP call, and a committed-data
            # thread would lease a pooled connection it never uses. The pool
            # (3 by default) is already held by this thread and the hold, so
            # the second prepare would wait for a connection, not for the row.
            prepares = requests.map { |request| Thread.new { section_9_3_recorded_prepare(request, answers:) } }
            waiters = holder_pid ? section_9_3_timekeeping_waiters(holder_pid, count: 2) : []
            # The first prepare waits on the held row, the second queues behind it.
            directly_blocked = waiters.select { |waiter| section_9_3_timekeeping_blocked_by?(waiter, holder_pid, within: 0) }
            # A reservation INSERT also waits on the held row (its foreign key
            # check locks the entry), so a wait proves the entry lock only when
            # the waiting statement is that lock's SELECT ... FOR UPDATE.
            entry_lock_waiters = waiters.select { |waiter| section_9_3_timekeeping_waiting_on_entry_lock?(waiter) }
            # Released before asserting, well inside the client's 5 s timeout.
            release << :release
            expect(waiters.size).to eq(2),
              "#{name}: both prepares should wait on the held entry row; Timekeeping sessions waiting: #{waiters.inspect}"
            expect(entry_lock_waiters).to eq(waiters),
              "#{name}: both prepares should wait in Timekeeping's entry-locking SELECT ... FOR UPDATE; " \
              "waiting sessions #{waiters.inspect}, of which in that SELECT #{entry_lock_waiters.inspect}"
            expect(directly_blocked).not_to be_empty,
              "#{name}: a prepare should be blocked by the held entry row itself; waiting sessions: #{waiters.inspect}"
            prepares.each { |prepare| prepare.join(TimekeepingSection93Live::DEFAULT_POLL_SECONDS) }
          ensure
            release << :release
            stop_committed_data_threads(hold, *prepares)
          end

          recorded = section_9_3_drain(answers)
          expect(recorded.map(&:status).sort).to eq([200, 409]),
            "#{name}: the two prepares answered #{recorded.map(&:status).inspect}"
          refusal = recorded.find { |answer| answer.status == 409 }&.body || {}
          expect(refusal["conflicts"]).to eq([{ "entry_id" => entry.id, "reason" => "provisional_elsewhere" }]),
            "#{name}: the refused prepare should name provisional_elsewhere; saw #{refusal.inspect}"
          reservations = section_9_3_reservations(company, [entry])
          expect(reservations.map { |row| row.fetch(:state) }).to eq(["provisional"]),
            "#{name}: the entry should hold one provisional reservation; saw #{reservations.inspect}"
          expect(invoices.map(&:id)).to include(reservations.first&.fetch(:invoice_id)),
            "#{name}: the provisional reservation should belong to one of the two invoices; saw #{reservations.inspect}"
        end
      end
    end
  end

  # Each save points a different existing line at a new entry with the same
  # rate and quantity, so neither writes the invoice row or the other's line.
  # A wait of the second save can then only be on the invoice-identity
  # advisory lock, which the example checks in pg_locks: blocked_by? alone
  # would also be true for a wait on a row lock.
  it "Two saves of one invoice start together: the second save waits on the invoice-identity lock, both commit, " \
     "and each entry has at most one committed reservation" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_each_company do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          first_held, second_held, first_added, second_added = ["first held", "second held", "first added", "second added"]
            .map { |label| section_9_3_fresh_entry(company:, employee:, project:, note: "Two saves: #{label}") }
          draft = section_9_3_draft_holding(company:, project:, entries: [first_held, second_held])
          first_line = draft.invoice_line_items.find_by!(timesheet_entry_id: first_held.id)
          second_line = draft.invoice_line_items.find_by!(timesheet_entry_id: second_held.id)
          parked = Queue.new
          release = Queue.new
          first_pids = Queue.new
          second_pids = Queue.new
          second = nil
          section_9_3_park_marked_saves!(parked:, release:)
          first = committed_data_thread(first_pids) do
            section_9_3_mark_save_to_park
            section_9_3_repoint_line(draft, first_line, first_added)
          end
          begin
            expect(parked.pop(timeout: TimekeepingSection93Live::DEFAULT_POLL_SECONDS)).to eq("prepared"),
              "#{name}: the first save should park holding the lock after a prepared answer"
            first_pid = first_pids.pop(timeout: 5)
            second = committed_data_thread(second_pids) { section_9_3_repoint_line(draft, second_line, second_added) }
            second_pid = second_pids.pop(timeout: 5)
            expect(blocked_by?(second_pid, first_pid)).to be(true),
              "#{name}: the second save should wait on the first save"
            expect(section_9_3_operation_lock?(second_pid, company_id: company.id, invoice_id: draft.id, granted: false))
              .to be(true), "#{name}: the second save should wait on the invoice-identity lock"
          ensure
            release << :release
            stop_committed_data_threads(first, second, wait: TimekeepingSection93Live::DEFAULT_POLL_SECONDS)
            section_9_3_restore_adapters!
          end

          intents = InvoiceOperationIntent.uncached do
            InvoiceOperationIntent.where(company_id: company.id, invoice_id: draft.id).order(:created_at).last(2)
          end
          expect(intents.map(&:state)).to eq(%w[committed committed]),
            "#{name}: both saves should commit; their intents are #{intents.map(&:state).inspect}"
          lines = InvoiceLineItem.uncached { draft.invoice_line_items.reload.pluck(:timesheet_entry_id) }
          expect(lines).to contain_exactly(first_added.id, second_added.id),
            "#{name}: the invoice should carry both saves' entries; its lines reference #{lines.inspect}"
          reservations = section_9_3_reservations(company, [first_held, second_held, first_added, second_added])
          committed_per_entry = reservations.filter_map { |row| row.fetch(:entry_id) if row.fetch(:state) == "committed" }.tally
          expect(committed_per_entry.values).to all(eq(1)),
            "#{name}: no entry may have two committed reservations; saw #{reservations.inspect}"
          expect(committed_per_entry.keys).to contain_exactly(first_added.id, second_added.id),
            "#{name}: the invoice should hold exactly its new entries committed; saw #{reservations.inspect}"
        end
      end
    end
  end

  # Recovery runs in this process while the worker's queue is paused, so the
  # worker's recurring sweep cannot settle the intent first.
  it "Crash after prepare, before the invoice commits: recovery waits while the save holds the lock and changes " \
     "nothing; after a killed save, recovery returns entries to their state before the save" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_with_paused_invoice_operations do
          section_9_3_each_company do |name, company|
            employee, project = section_9_3_employee_and_project(company)

            # The save is paused after prepare, still holding the lock.
            held = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the paused draft")
            added = section_9_3_fresh_entry(company:, employee:, project:, note: "Added by the paused save")
            draft = section_9_3_draft_holding(company:, project:, entries: [held])
            parked = Queue.new
            release = Queue.new
            save_pids = Queue.new
            recovery_pids = Queue.new
            recovery = nil
            section_9_3_park_marked_saves!(parked:, release:)
            save = committed_data_thread(save_pids) do
              section_9_3_mark_save_to_park
              Invoice.find(draft.id).update!(invoice_line_items_attributes: [section_9_3_line(added)])
            end
            begin
              expect(parked.pop(timeout: TimekeepingSection93Live::DEFAULT_POLL_SECONDS)).to eq("prepared"),
                "#{name}: the save should park holding the lock after a prepared answer"
              save_pid = save_pids.pop(timeout: 5)
              before = section_9_3_recovery_snapshot(company, draft, [held, added])
              recovery = committed_data_thread(recovery_pids) { section_9_3_recover_now }
              # Observed within 3 s, inside recovery's 5 s lock wait.
              expect(blocked_by?(recovery_pids.pop(timeout: 5), save_pid)).to be(true),
                "#{name}: recovery should wait on the paused save's lock"
              # An unchanged snapshot proves something only once recovery has
              # returned; join answers nil when the thread is still running.
              expect(recovery.join(TimekeepingSection93Live::DEFAULT_POLL_SECONDS)).to be(recovery),
                "#{name}: recovery should return after its lock wait ends"
              after = section_9_3_recovery_snapshot(company, draft, [held, added])
              expect(after).to eq(before),
                "#{name}: recovery beside a live save should change nothing; before #{before.inspect}, after #{after.inspect}"
            ensure
              release << :release
              stop_committed_data_threads(recovery, save, wait: TimekeepingSection93Live::DEFAULT_POLL_SECONDS)
              section_9_3_restore_adapters!
            end
            expect(section_9_3_latest_intent(company, draft)&.state).to eq("committed"),
              "#{name}: the released save should commit"

            # The save is killed after prepare.
            held = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the crashed draft")
            added = section_9_3_fresh_entry(company:, employee:, project:, note: "Added by the crashed save")
            draft = section_9_3_draft_holding(company:, project:, entries: [held])
            baseline = section_9_3_reservations(company, [held, added])
            section_9_3_crash_at_checkpoint(company_id: company.id, invoice_id: draft.id) do |checkpoint|
              allow(Invoices::ReservationAdapters).to receive(:for).and_wrap_original do |original, *args|
                section_9_3_after_prepare(original.call(*args)) { |outcome| checkpoint.call if outcome.state == "prepared" }
              end
              Invoice.find(draft.id).update!(invoice_line_items_attributes: [section_9_3_line(added)])
            end

            intent = section_9_3_latest_intent(company, draft)
            expect(intent&.state).to eq("pending"), "#{name}: the crashed save's intent is #{intent&.state.inspect}"
            prepared = section_9_3_reservations(company, [added])
            expect(prepared.map { |row| row.fetch(:state) }).to eq(["provisional"]),
              "#{name}: the crashed save's prepare should keep a provisional reservation; saw #{prepared.inspect}"

            section_9_3_recover_now

            intent = section_9_3_latest_intent(company, draft)
            expect(intent&.state).to eq("failed"), "#{name}: recovery should fail the crashed intent; it is #{intent&.state.inspect}"
            if intent
              state = section_9_3_await_abort(name, company, draft, intent)
              expect(state).to eq("aborted"), "#{name}: the crashed save's operation is #{state.inspect}"
            end
            after = section_9_3_reservations(company, [held, added])
            expect(after).to eq(baseline),
              "#{name}: reservations after recovery #{after.inspect} differ from before the save #{baseline.inspect}"
          end
        end
      end
    end
  end

  # The prepare fails by losing its answer after Timekeeping applied it, so the
  # abort that recovery delivers can finish the stored operation. The child is
  # killed inside the failure transaction, after it wrote the abort row and
  # before that transaction commits.
  it "Crash after the intent is set `failed`, before the abort outbox row exists: the intent is still pending, " \
     "and recovery records failed and delivers the abort" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_with_paused_invoice_operations do
          section_9_3_each_company do |name, company|
            employee, project = section_9_3_employee_and_project(company)
            held = section_9_3_fresh_entry(company:, employee:, project:, note: "Held by the draft")
            added = section_9_3_fresh_entry(company:, employee:, project:, note: "Added by the failing save")
            draft = section_9_3_draft_holding(company:, project:, entries: [held])
            baseline = section_9_3_reservations(company, [held, added])

            section_9_3_crash_at_checkpoint(company_id: company.id, invoice_id: draft.id) do |checkpoint|
              allow(Invoices::ReservationAdapters).to receive(:for).and_return(section_9_3_client_dropping_first_prepare)
              allow(InvoiceOperationOutboxItem).to receive(:record!).and_wrap_original do |original, **fields|
                original.call(**fields).tap { checkpoint.call if fields.fetch(:kind) == "abort" }
              end
              Invoice.find(draft.id).update!(invoice_line_items_attributes: [section_9_3_line(added)])
            end

            intent = section_9_3_latest_intent(company, draft)
            expect(intent&.state).to eq("pending"), "#{name}: the crashed save's intent is #{intent&.state.inspect}"
            aborts = InvoiceOperationOutboxItem.uncached do
              InvoiceOperationOutboxItem.where(company_id: company.id, invoice_id: draft.id, kind: "abort").count
            end
            expect(aborts).to eq(0), "#{name}: the killed failure transaction should leave no abort row"

            section_9_3_recover_now

            intent = section_9_3_latest_intent(company, draft)
            expect(intent&.state).to eq("failed"), "#{name}: recovery should record failed; the intent is #{intent&.state.inspect}"
            if intent
              delivered = InvoiceOperationOutboxItem.uncached do
                InvoiceOperationOutboxItem.where(company_id: company.id, operation_id: intent.operation_id, kind: "abort")
                  .pluck(:delivered_at)
              end
              expect(delivered.size).to eq(1), "#{name}: recovery should write one abort row; saw #{delivered.size}"
              expect(delivered).to all(be_present), "#{name}: the abort row should be delivered"
              state = section_9_3_await_abort(name, company, draft, intent)
              expect(state).to eq("aborted"), "#{name}: the failed save's operation is #{state.inspect}"
            end
            after = section_9_3_reservations(company, [held, added])
            expect(after).to eq(baseline),
              "#{name}: reservations after the abort #{after.inspect} differ from before the save #{baseline.inspect}"
          end
        end
      end
    end
  end
end

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

  def section_9_3_bulk_delete(company, invoice)
    owner = company.users.with_role(:owner, company).order(:id).first!
    sign_in owner
    send_request :post, api_v1_invoices_bulk_deletion_index_path, params: { invoices_ids: [invoice.id] },
      headers: auth_headers(owner)
    response
  end

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  it "Prepare answer lost (timeout or 5xx): the save fails, the intent is failed, and after abort each entry's " \
     "reservation equals its state before the save" do
    section_9_3_live_context do
      section_9_3_cutover!

      aggregate_failures do
        section_9_3_companies.each do |name, company|
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
            state = section_9_3_poll_until("#{name}: abort of operation #{intent.operation_id}",
                                           satisfied: ->(observed) { observed == "aborted" }) do
              section_9_3_operation_state(company, draft, intent.operation_id)
            end
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
        section_9_3_companies.each do |name, company|
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
            state = section_9_3_poll_until("#{name}: abort of operation #{intent.operation_id}",
                                           satisfied: ->(observed) { observed == "aborted" }) do
              section_9_3_operation_state(company, draft, intent.operation_id)
            end
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
        section_9_3_companies.each do |name, company|
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
          if intent
            section_9_3_poll_until("#{name}: abort of operation #{intent.operation_id}",
                                   satisfied: ->(observed) { observed == "aborted" }) do
              section_9_3_operation_state(company, draft, intent.operation_id)
            end
          end
          after = section_9_3_reservations(company, [entry])
          expect(section_9_3_committed_by(after, entry, draft).size).to eq(1),
            "#{name}: the entry should still be reserved by the committed draft; saw #{after.inspect}"
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
        section_9_3_companies.each do |name, company|
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
        section_9_3_companies.each do |name, company|
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
        section_9_3_companies.each do |name, company|
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
        section_9_3_companies.each do |name, company|
          employee, project = section_9_3_employee_and_project(company)
          entry = section_9_3_fresh_entry(company:, employee:, project:, note: "On the paid invoice")
          invoice = section_9_3_non_draft_holding(company:, project:, entries: [entry])
          create(:payment, invoice:, amount: 10)
          lines_before = invoice.invoice_line_items.order(:id).pluck(:id, :timesheet_entry_id)
          baseline = section_9_3_reservations(company, [entry])
          expect(section_9_3_committed_by(baseline, entry, invoice).size).to eq(1),
            "#{name}: the non-draft should hold its entry committed before the delete; saw #{baseline.inspect}"

          answer = section_9_3_bulk_delete(company, invoice)

          expect(answer.status).to eq(422), "#{name}: the bulk delete answered #{answer.status}"
          expect(JSON.parse(answer.body).fetch("undeletable_invoice_ids")).to eq([invoice.id]),
            "#{name}: the refusal should name the paid invoice"
          expect(Invoice.unscoped.exists?(id: invoice.id)).to be(true), "#{name}: the paid invoice should remain"
          expect(InvoiceLineItem.where(invoice_id: invoice.id).order(:id).pluck(:id, :timesheet_entry_id))
            .to eq(lines_before), "#{name}: the paid invoice's line items should be unchanged"
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
        section_9_3_companies.each do |name, company|
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
end

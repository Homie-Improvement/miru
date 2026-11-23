# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:user) { timekeeping_arrange.user(company:, role: "employee") }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:x) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:y) { timekeeping_arrange.entry(company:, user:, project:) }

  def reservation_request(route, operation_id:, invoice_id: 501, entry_ids: [], disposition: "active",
                          actor_name: "invoice-boundary", generation: timekeeping_arrange.current_generation,
                          company_id: company)
    Timekeeping::ReservationOperations::Request.new(
      route:, company_id:, actor_name:, invoice_id:, operation_id:,
      generation:, disposition:, entry_ids:
    )
  end

  # These examples test reservation rules, not invoice ownership, and some prepare one invoice id for two
  # companies, so every invoice counts as the requesting company's here.
  def every_invoice_owned
    ->(company_id:, invoice_id:) { true }
  end

  def run_operation(route, **options)
    outcome = described_class.new(invoice_owned: every_invoice_owned).call(reservation_request(route, **options))
    [outcome.status, JSON.parse(outcome.body)]
  end

  # Prepares and commits entry_ids for the invoice under a new operation id.
  def commit_entries(entry_ids, invoice_id: 501, disposition: "active")
    operation_id = SecureRandom.uuid
    expect(run_operation(:prepare, operation_id:, invoice_id:, entry_ids:, disposition:).first).to eq(200)
    run_operation(:commit, operation_id:, invoice_id:)
  end

  def held(entry_id)
    Reservation.where(entry_id:).order(:invoice_id).pluck(:invoice_id, :state)
  end

  it "leaves no reservation, operation, audit or outbox row when the outbox insert fails after the reservation write" do
    x
    before = reservation_row_counts
    allow(OutboxSnapshot).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "outbox down")

    expect { run_operation(:prepare, operation_id: SecureRandom.uuid, entry_ids: [x]) }
      .to raise_error(ActiveRecord::StatementInvalid, "outbox down")
    expect(reservation_row_counts).to eq(before)
  end

  it "keeps no prepared row after a conflict, so the same operation id succeeds with a corrected entry set" do
    commit_entries([x], invoice_id: 502)
    y
    before = reservation_row_counts
    operation_id = SecureRandom.uuid

    refused = run_operation(:prepare, operation_id:, entry_ids: [y, x])

    expect(refused).to eq([409, { "reason" => "conflict", "conflicts" => [{ "entry_id" => x, "reason" => "on_another_invoice" }] }])
    expect(reservation_row_counts).to eq(before)
    expect(run_operation(:prepare, operation_id:, entry_ids: [y])).to eq(
      [200, { "operation_id" => operation_id, "state" => "prepared", "entries" => [{ "entry_id" => y, "company_id" => company }] }]
    )
  end

  it "changes no row count or version when commit, abort and prepare are replayed after commit" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])
    first = run_operation(:commit, operation_id:)
    after_commit = reservation_row_counts

    expect(run_operation(:commit, operation_id:)).to eq(first)
    expect(run_operation(:abort, operation_id:)).to eq([200, { "dropped" => 0 }])
    expect(run_operation(:prepare, operation_id:, entry_ids: [x]).last.fetch("state")).to eq("committed")
    expect(reservation_row_counts.except(:receipts)).to eq(after_commit.except(:receipts))
    expect(held(x)).to eq([[501, "committed"]])
  end

  it "reserves separately for another service using the same operation id, and its abort keeps the first service's rows" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])

    other = run_operation(:prepare, operation_id:, invoice_id: 502, entry_ids: [y], actor_name: "agent-destroy")

    expect(other.first).to eq(200)
    expect(run_operation(:abort, operation_id:, invoice_id: 502, actor_name: "agent-destroy")).to eq([200, { "dropped" => 1 }])
    expect([held(x), held(y)]).to eq([[[501, "provisional"]], []])
  end

  it "commits only the set prepare stored, ignoring entries sent with the commit" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])

    expect(run_operation(:commit, operation_id:, entry_ids: [x, y])).to eq([200, { "reserved" => 1, "released" => 0 }])
    expect([held(x), held(y)]).to eq([[[501, "committed"]], []])
  end

  it "releases nothing on a retained commit whose stored set drops an entry" do
    commit_entries([x, y])

    expect(commit_entries([x], disposition: "retained")).to eq([200, { "reserved" => 0, "released" => 0 }])
    expect(held(y)).to eq([[501, "committed"]])
    expect(Reservation.where(invoice_id: 501).distinct.pluck(:disposition)).to eq(["retained"])
  end

  it "writes no audit, outbox or version change when a provisional reservation becomes committed" do
    operation_id = SecureRandom.uuid
    run_operation(:prepare, operation_id:, entry_ids: [x])
    before = [AuditEvent.where(entry_id: x).count, OutboxSnapshot.where(id: x).count, Entry.find(x).version]

    run_operation(:commit, operation_id:)

    expect([AuditEvent.where(entry_id: x).count, OutboxSnapshot.where(id: x).count, Entry.find(x).version]).to eq(before)
  end

  it "flips locked, raises the version and writes one service audit row and one snapshot when a commit releases an entry" do
    commit_entries([x, y])
    version = Entry.find(y).version
    audits = AuditEvent.where(entry_id: y).count

    expect(commit_entries([x])).to eq([200, { "reserved" => 0, "released" => 1 }])

    expect(Entry.find(y).version).to eq(version + 1)
    expect(AuditEvent.where(entry_id: y).count).to eq(audits + 1)
    audit = AuditEvent.where(entry_id: y).order(:id).last
    expect([audit.actor_type, audit.actor_name, audit.actor_id, audit.action, audit.before, audit.after])
      .to eq(["service", "invoice-boundary", nil, "commit", { "locked" => true }, { "locked" => false }])
    snapshot = OutboxSnapshot.where(id: y).order(:outbox_position).last
    expect([snapshot.locked, snapshot.version]).to eq([false, version + 1])
  end

  describe "a retained owner and a successor preparing the same entry" do
    # "commit makes the desired set the reservation set": whichever invoice
    # prepares the retained entry first holds it, the other is refused, and a
    # successful commit always leaves its whole desired set reserved.
    let(:provisional_elsewhere) do
      [409, { "reason" => "conflict", "conflicts" => [{ "entry_id" => x, "reason" => "provisional_elsewhere" }] }]
    end

    def held_with_disposition(entry_id)
      Reservation.where(entry_id:).order(:invoice_id).pluck(:invoice_id, :state, :disposition)
    end

    before { commit_entries([x], invoice_id: 501, disposition: "retained") }

    it "refuses the successor while the owner's active prepare holds the entry, then commits the owner's whole set" do
      owner_id = SecureRandom.uuid

      expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x, y]).first).to eq(200)
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, invoice_id: 502, entry_ids: [x]))
        .to eq(provisional_elsewhere)

      expect(run_operation(:commit, operation_id: owner_id, invoice_id: 501))
        .to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[501, "committed", "active"]])
      expect(held_with_disposition(y)).to eq([[501, "committed", "active"]])
    end

    it "refuses the owner while the successor's prepare holds the entry, then hands the entry to the successor" do
      successor_id = SecureRandom.uuid

      expect(run_operation(:prepare, operation_id: successor_id, invoice_id: 502, entry_ids: [x, y]).first).to eq(200)
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, invoice_id: 501, entry_ids: [x]))
        .to eq(provisional_elsewhere)

      expect(run_operation(:commit, operation_id: successor_id, invoice_id: 502))
        .to eq([200, { "reserved" => 2, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[502, "committed", "active"]])
      expect(held_with_disposition(y)).to eq([[502, "committed", "active"]])
    end

    it "leaves the retained reservation as it was when the owner's prepare aborts, so a successor may then take it" do
      owner_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x, y]).first).to eq(200)

      expect(run_operation(:abort, operation_id: owner_id, invoice_id: 501)).to eq([200, { "dropped" => 1 }])
      expect(held_with_disposition(x)).to eq([[501, "committed", "retained"]])
      expect(held(y)).to eq([])

      successor_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: successor_id, invoice_id: 502, entry_ids: [x]).first).to eq(200)
      expect(run_operation(:commit, operation_id: successor_id, invoice_id: 502))
        .to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[502, "committed", "active"]])
    end

    it "keeps the entry retained when the owner prepares it again as retained" do
      owner_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: owner_id, invoice_id: 501, entry_ids: [x], disposition: "retained")
               .first).to eq(200)
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, invoice_id: 502, entry_ids: [x]))
        .to eq(provisional_elsewhere)

      expect(run_operation(:commit, operation_id: owner_id, invoice_id: 501))
        .to eq([200, { "reserved" => 0, "released" => 0 }])
      expect(held_with_disposition(x)).to eq([[501, "committed", "retained"]])
    end
  end

  # Generated by Descant: acceptance tests below.
  # A finished operation must answer from what it stored even after the generation moves on, because the
  # stored answer is read before the generation is checked. Each test ends with a control: the same old
  # generation under a new operation id is refused, which proves the replay really was sent stale.
  describe "a finished operation replayed with its original generation after the generation advances" do
    let(:stale_generation) { [409, { "reason" => "stale_generation" }] }

    it "replays a finished prepare from its operation row, still prepared, and changes nothing" do
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      first = run_operation(:prepare, operation_id:, entry_ids: [x])
      expect(first).to eq(
        [200, { "operation_id" => operation_id, "state" => "prepared", "entries" => [{ "entry_id" => x, "company_id" => company }] }]
      )
      timekeeping_arrange.set_generation(original + 1)
      expect(held(x)).to eq([[501, "provisional"]])
      baseline = reservation_row_counts

      expect(run_operation(:prepare, operation_id:, entry_ids: [x], generation: original)).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([[501, "provisional"]])
      expect(run_operation(:prepare, operation_id: SecureRandom.uuid, entry_ids: [x], generation: original))
        .to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end

    it "replays a finished commit from its receipt and changes nothing" do
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      run_operation(:prepare, operation_id:, entry_ids: [x])
      first = run_operation(:commit, operation_id:)
      expect(first).to eq([200, { "reserved" => 1, "released" => 0 }])
      timekeeping_arrange.set_generation(original + 1)
      expect(held(x)).to eq([[501, "committed"]])
      baseline = reservation_row_counts

      expect(run_operation(:commit, operation_id:, generation: original)).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([[501, "committed"]])
      expect(run_operation(:commit, operation_id: SecureRandom.uuid, generation: original)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end

    it "replays a finished abort from its receipt and changes nothing" do
      operation_id = SecureRandom.uuid
      original = timekeeping_arrange.current_generation
      run_operation(:prepare, operation_id:, entry_ids: [x])
      first = run_operation(:abort, operation_id:)
      expect(first).to eq([200, { "dropped" => 1 }])
      timekeeping_arrange.set_generation(original + 1)
      expect(held(x)).to eq([])
      baseline = reservation_row_counts

      expect(run_operation(:abort, operation_id:, generation: original)).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([])
      expect(run_operation(:abort, operation_id: SecureRandom.uuid, generation: original)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end
  end

  # During a handoff's settle step Timekeeping is fenced, yet it still applies a commit or abort that carries
  # the settling generation for an operation it stored at that generation. Everything else is stale_generation.
  describe "settle step" do
    let(:stale_generation) { [409, { "reason" => "stale_generation" }] }

    # Another company with one entry of its own.
    def settle_step_company_with_entry
      other = timekeeping_arrange.company
      other_user = timekeeping_arrange.user(company: other, role: "employee")
      other_project = timekeeping_arrange.project(company: other)
      [other, timekeeping_arrange.entry(company: other, user: other_user, project: other_project)]
    end

    def settle_step_stored_state
      reservation_row_counts.merge(
        operation_states: InvoiceOperation.order(:id).pluck(:operation_id, :state),
        admission: Timekeeping::Admission.current.attributes
      )
    end

    # "a commit of a prepared operation at the outgoing generation is applied."
    # "After stop_applying! the same commit is refused as stale, even when it was applied during settling and has a stored receipt"
    it "applies a commit at the outgoing generation once, and after stop_applying! the same request is refused as stale with nothing stored" do
      timekeeping_arrange.set_generation(5)
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, generation: 5, entry_ids: [x]).first).to eq(200)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)

      applied = run_operation(:commit, operation_id:, generation: 5)
      expect(applied).to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(InvoiceOperation.find_by!(operation_id:).state).to eq("committed")
      expect(held(x)).to eq([[501, "committed"]])
      expect(ServiceIdempotencyReceipt.where(key: operation_id, operation: "commit").count).to eq(1)
      after_commit = reservation_row_counts

      # A retry of the delivered commit while still settling has no second effect.
      expect(run_operation(:commit, operation_id:, generation: 5)).to eq(applied)
      expect(reservation_row_counts).to eq(after_commit)

      Timekeeping::Admission.stop_applying!(generation: 5)

      expect(run_operation(:commit, operation_id:, generation: 5)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(after_commit)
      expect(InvoiceOperation.find_by!(operation_id:).state).to eq("committed")

      # A settle that timed out and ran late cannot reopen the phase for it.
      Timekeeping::Admission.begin_settling!(generation: 5)
      expect(run_operation(:commit, operation_id:, generation: 5)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(after_commit)
    end

    # "During this step only, the outgoing owner still applies a commit or abort that carries the old
    # generation, and only for an operation it registered in its own invoice_operations."
    it "applies an abort during settling and writes its unlock snapshot at the outgoing generation" do
      timekeeping_arrange.set_generation(5)
      operation_id = SecureRandom.uuid
      run_operation(:prepare, operation_id:, generation: 5, entry_ids: [x])
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      snapshots_before = OutboxSnapshot.count
      at_five_before = OutboxSnapshot.where(generation: 5).count

      expect(run_operation(:abort, operation_id:, generation: 5)).to eq([200, { "dropped" => 1 }])
      expect(InvoiceOperation.find_by!(operation_id:).state).to eq("aborted")
      expect(Reservation.where(entry_id: x).count).to eq(0)
      expect(OutboxSnapshot.count).to eq(snapshots_before + 1)
      expect(OutboxSnapshot.where(generation: 5).count).to eq(at_five_before + 1)
    end

    # "Settle, then stop, then settle again at the same generation: the same commit is still refused."
    it "still refuses the commit after settle, stop and a repeated settle at the same generation" do
      timekeeping_arrange.set_generation(5)
      operation_id = SecureRandom.uuid
      run_operation(:prepare, operation_id:, generation: 5, entry_ids: [x])
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      Timekeeping::Admission.stop_applying!(generation: 5)
      Timekeeping::Admission.begin_settling!(generation: 5)
      baseline = reservation_row_counts

      expect(Timekeeping::Admission.settling?).to be(false)
      expect(run_operation(:commit, operation_id:, generation: 5)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
      expect(InvoiceOperation.find_by!(operation_id:).state).to eq("prepared")
    end

    # "it names an operation in Timekeeping's own invoice_operations, found by company, actor and operation id,
    # stored at that generation."
    # "Everything else is refused as stale_generation, with no stored change and no new invoice_operations row."
    it "refuses another company's commit naming this company's operation id, changes nothing, and still applies the owning company's commit" do
      outgoing = timekeeping_arrange.current_generation.to_s
      other_company, = settle_step_company_with_entry
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, generation: outgoing, entry_ids: [x]).first).to eq(200)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: Integer(outgoing))
      expect(Timekeeping::Admission.settling?).to be(true)
      baseline = reservation_row_counts
      expect(baseline.fetch(:operations)).to eq(1)
      expect(Reservation.where(entry_id: x).pluck(:company_id, :state)).to eq([[company, "provisional"]])

      refused = run_operation(:commit, operation_id:, generation: outgoing, company_id: other_company)

      expect(refused).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
      expect(InvoiceOperation.where(operation_id:).pluck(:company_id, :state)).to eq([[company, "prepared"]])
      expect(InvoiceOperation.where(company_id: other_company).count).to eq(0)
      expect(Reservation.where(entry_id: x).pluck(:state)).to eq(["provisional"])

      applied = run_operation(:commit, operation_id:, generation: outgoing)

      expect(applied).to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(InvoiceOperation.find_by!(company_id: company, operation_id:).state).to eq("committed")
    end

    it "applies a company's commit only to its own operation and leaves another company's prepared operation with the same id untouched" do
      outgoing = timekeeping_arrange.current_generation.to_s
      other_company, other_entry = settle_step_company_with_entry
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, generation: outgoing, entry_ids: [x]).first).to eq(200)
      expect(run_operation(:prepare, operation_id:, generation: outgoing, entry_ids: [other_entry],
                                     company_id: other_company).first).to eq(200)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: Integer(outgoing))

      applied = run_operation(:commit, operation_id:, generation: outgoing, company_id: other_company)

      expect(applied).to eq([200, { "reserved" => 1, "released" => 0 }])
      expect(InvoiceOperation.where(operation_id:).order(:company_id).pluck(:company_id, :state))
        .to eq([[company, "prepared"], [other_company, "committed"]].sort_by(&:first))
      expect(Reservation.where(entry_id: x).pluck(:company_id, :state)).to eq([[company, "provisional"]])
      expect(Reservation.where(entry_id: other_entry).pluck(:company_id, :state)).to eq([[other_company, "committed"]])
      expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(0)
    end

    # "In `Timekeeping::ReservationOperations` (timekeeping/app/services/timekeeping/reservation_operations.rb), while admission is fenced, apply a request only when all three hold: it is a commit or abort; it carries exactly `settling_generation`; and it names an operation in Timekeeping's own invoice_operations, found by company, actor and operation id, stored at that generation."
    # "Everything else is refused as stale_generation, with no stored change and no new invoice_operations row."
    it "refuses a commit with the wrong actor, a malformed or raised generation, an older-generation operation, or a new prepare, and stores nothing" do
      timekeeping_arrange.set_generation(4)
      older_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id: older_id, generation: 4, invoice_id: 502, entry_ids: [y]).first).to eq(200)
      timekeeping_arrange.set_generation(5)
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, generation: 5, entry_ids: [x]).first).to eq(200)
      unreserved_entry = timekeeping_arrange.entry(company:, user:, project:)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      baseline = settle_step_stored_state
      expect(baseline[:operation_states]).to eq([[older_id, "prepared"], [operation_id, "prepared"]])
      expect(baseline[:admission]).to include("generation" => nil, "settling_generation" => 5)

      refused = {
        "another actor, same operation id" => [:commit, { operation_id:, generation: 5, actor_name: "agent-destroy" }],
        "generation 5.0" => [:commit, { operation_id:, generation: "5.0" }],
        "generation with a leading space" => [:commit, { operation_id:, generation: " 5" }],
        "no generation" => [:commit, { operation_id:, generation: nil }],
        "the raised generation" => [:commit, { operation_id:, generation: 6 }],
        "operation stored at generation 4" => [:commit, { operation_id: older_id, generation: 5, invoice_id: 502 }],
        "abort of operation stored at generation 4" => [:abort, { operation_id: older_id, generation: 5, invoice_id: 502 }],
        "unknown operation" => [:commit, { operation_id: SecureRandom.uuid, generation: 5 }],
        "new prepare at the settling generation" =>
          [:prepare, { operation_id: SecureRandom.uuid, generation: 5, invoice_id: 503, entry_ids: [unreserved_entry] }],
        "operation stored at generation 4, sent at 4" => [:commit, { operation_id: older_id, generation: 4, invoice_id: 502 }],
        "abort of operation stored at generation 4, sent at 4" =>
          [:abort, { operation_id: older_id, generation: 4, invoice_id: 502 }],
        "abort by another actor" => [:abort, { operation_id:, generation: 5, actor_name: "other-boundary" }]
      }

      refused.each do |label, (route, options)|
        expect(run_operation(route, **options)).to eq(stale_generation), label
        expect(settle_step_stored_state).to eq(baseline), "#{label} changed stored state"
      end
    end

    # "While settling, Timekeeping applies a commit or abort of an operation it registered at the outgoing
    # generation, and refuses new writes, prepares and commands"
    # "`EntryWriter` and `ServiceCommands` keep reading `Admission.locked_generation` and stay refused."
    it "refuses an entry update and an entry create sent at the settling generation while generation 5 is settling" do
      timekeeping_arrange.set_generation(5)
      owner = timekeeping_arrange.user(company:, role: "owner")
      entry_id = timekeeping_arrange.entry(company:, user: owner, project:)
      token = timekeeping_arrange.token_for(owner)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      expect(Timekeeping::Admission.settling?).to be(true)
      note = Entry.find(entry_id).note
      baseline = entry_write_counts.merge(reservation_row_counts)
      expect(baseline[:entries]).to eq(1)

      update = build_entry_command(:update, token:, entry_id:, body: { "note" => "Edited" }, generation: 5)
      updated = Timekeeping::EntryWriter.new.call(update)
      expect([updated.status, JSON.parse(updated.body)]).to eq(stale_generation)
      expect(entry_write_counts.merge(reservation_row_counts)).to eq(baseline)
      expect(Entry.find(entry_id).note).to eq(note)

      create = build_entry_command(:create, token:, generation: 5,
                                            body: { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0,
                                                    "note" => "Planning", "source" => "manual", "source_metadata" => {} })
      created = Timekeeping::EntryWriter.new.call(create)
      expect([created.status, JSON.parse(created.body)]).to eq(stale_generation)
      expect(entry_write_counts.merge(reservation_row_counts)).to eq(baseline)
      expect(Timekeeping::Admission.settling?).to be(true)
    end

    it "refuses mark-billed and detach-entries sent at the settling generation while generation 5 is settling" do
      run_service_command = lambda do |route, target_id|
        request = Timekeeping::ServiceCommands::Request.new(route:, company_id: company, actor_name: "invoice-boundary",
                                                            target_id:, operation_id: SecureRandom.uuid, generation: 5)
        outcome = Timekeeping::ServiceCommands.new.call(request)
        [outcome.status, JSON.parse(outcome.body)]
      end
      timekeeping_arrange.set_generation(5)
      billable = timekeeping_arrange.reserved_entry(company:, invoice_id: 501)
      attached = timekeeping_arrange.entry(company:, user:, project:, agent_id: 77)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      expect(Timekeeping::Admission.settling?).to be(true)
      baseline = reservation_row_counts
      expect([Entry.find(billable).bill_status, Entry.find(attached).agent_id]).to eq(["unbilled", 77])

      expect(run_service_command.call(:mark_billed, 501)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
      expect(Entry.find(billable).bill_status).to eq("unbilled")

      expect(run_service_command.call(:detach_entries, 77)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
      expect(Entry.find(attached).agent_id).to eq(77)
    end

    # "Outside a fence, keep the receipt-first order."
    it "replays a commit from its receipt after the handoff admits generation 6, keeping the receipt-first order outside a fence" do
      timekeeping_arrange.set_generation(5)
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, generation: "5", entry_ids: [x]).first).to eq(200)
      first = run_operation(:commit, operation_id:, generation: "5")
      expect(first).to eq([200, { "reserved" => 1, "released" => 0 }])

      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      Timekeeping::Admission.stop_applying!(generation: 5)
      timekeeping_arrange.set_generation(6)
      expect(Timekeeping::Admission.settling?).to be(false)
      baseline = reservation_row_counts

      expect(run_operation(:commit, operation_id:, generation: "5")).to eq(first)
      expect(reservation_row_counts).to eq(baseline)
      expect(held(x)).to eq([[501, "committed"]])
      expect(run_operation(:commit, operation_id: SecureRandom.uuid, generation: "5")).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end

    it "answers stale_generation, not the stored receipt, when a commit re-sent after stop_applying! reaches the unique-violation backstop" do
      timekeeping_arrange.set_generation(5)
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, generation: 5, entry_ids: [x]).first).to eq(200)
      Timekeeping::Admission.fence!(lock_timeout: 1)
      Timekeeping::Admission.begin_settling!(generation: 5)
      expect(run_operation(:commit, operation_id:, generation: 5).first).to eq(200)
      Timekeeping::Admission.stop_applying!(generation: 5)
      baseline = reservation_row_counts

      # Sends the request straight to the unique-violation rescue in call.
      allow(Timekeeping::WriteSteps).to receive(:lock_key).and_raise(ActiveRecord::RecordNotUnique)

      expect(run_operation(:commit, operation_id:, generation: 5)).to eq(stale_generation)
      expect(reservation_row_counts).to eq(baseline)
    end
  end

  context "when prepare names an invoice the company may not own" do
    def prepare_with(invoice_owned, operation_id: SecureRandom.uuid)
      outcome = described_class.new(invoice_owned:)
        .call(reservation_request(:prepare, operation_id:, entry_ids: [x]))
      [outcome.status, JSON.parse(outcome.body)]
    end

    it "answers not_found and writes nothing when the invoice is not the company's, so the same key prepares later" do
      x
      before = reservation_row_counts
      operation_id = SecureRandom.uuid

      expect(prepare_with(->(company_id:, invoice_id:) { false }, operation_id:)).to eq([404, { "reason" => "not_found" }])
      expect(reservation_row_counts).to eq(before)
      expect(InvoiceOperation.where(operation_id:).count).to eq(0)
      expect(prepare_with(every_invoice_owned, operation_id:).first).to eq(200)
    end

    it "answers reference_unavailable and writes nothing when the invoice's owner cannot be read" do
      x
      before = reservation_row_counts
      unreadable = ->(company_id:, invoice_id:) { raise Timekeeping::ReferenceClient::Unavailable, "down" }

      expect(prepare_with(unreadable)).to eq([503, { "reason" => "reference_unavailable" }])
      expect(reservation_row_counts).to eq(before)
    end

    it "asks only prepare about the owner: commit and abort act on the operation the company stored" do
      operation_id = SecureRandom.uuid
      expect(run_operation(:prepare, operation_id:, entry_ids: [x]).first).to eq(200)
      refusing = ->(company_id:, invoice_id:) { raise "commit must not ask who owns the invoice" }

      committed = described_class.new(invoice_owned: refusing).call(reservation_request(:commit, operation_id:))

      expect([committed.status, JSON.parse(committed.body)]).to eq([200, { "reserved" => 1, "released" => 0 }])
    end
  end
end

RSpec.describe Timekeeping::InvoiceOwnership do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:other_company) { timekeeping_arrange.company }

  def store_invoice_operation(company_id, invoice_id)
    InvoiceOperation.create!(company_id:, invoice_id:, operation_id: SecureRandom.uuid, actor_name: "invoice-boundary",
                             state: "committed", desired_entry_ids: [], disposition: "active", generation: 1,
                             created_at: Time.current)
  end

  it "counts an invoice the company's own invoice_operations hold without asking the monolith" do
    store_invoice_operation(company, 771)
    unreachable = WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)

    expect(described_class.owned?(company_id: company, invoice_id: 771)).to be(true)
    expect(unreachable).not_to have_been_requested
  end

  it "asks the monolith when only another company's invoice_operations hold the invoice, and follows its answer" do
    store_invoice_operation(other_company, 772)
    timekeeping_arrange.invoice(company: other_company, invoice_id: 772)
    timekeeping_arrange.invoice(company:, invoice_id: 773)

    expect(described_class.owned?(company_id: company, invoice_id: 772)).to be(false)
    expect(described_class.owned?(company_id: company, invoice_id: 773)).to be(true)
  end

  it "raises Unavailable rather than answer when the monolith cannot say" do
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)

    expect { described_class.owned?(company_id: company, invoice_id: 774) }
      .to raise_error(Timekeeping::ReferenceClient::Unavailable)
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Timekeeping::ReservationOperations do
  include_context "timekeeping entry writes"

  let(:company) { timekeeping_arrange.company }
  let(:user) { timekeeping_arrange.user(company:, role: "employee") }
  let(:project) { timekeeping_arrange.project(company:) }
  let(:kept_entry) { timekeeping_arrange.entry(company:, user:, project:) }
  let(:released_entry) { timekeeping_arrange.entry(company:, user:, project:) }

  def unpublishable_reservation_call(route, operation_id:, entry_ids: [])
    request = Timekeeping::ReservationOperations::Request.new(
      route:, company_id: company, actor_name: "invoice-boundary", invoice_id: 501, operation_id:,
      generation: timekeeping_arrange.current_generation, disposition: "active", entry_ids:
    )
    # These examples test unpublishable rows, not invoice ownership.
    outcome = described_class.new(invoice_owned: ->(company_id:, invoice_id:) { true }).call(request)
    [outcome.status, JSON.parse(outcome.body)]
  end

  it "refuses a prepare that would lock an entry with a stored unknown review status and leaves no operation" do
    bad = timekeeping_arrange.entry(company:, user:, project:)
    Entry.find(bad).update_column(:review_status, "unknown")
    before = reservation_row_counts
    version = Entry.find(bad).version
    operation_id = SecureRandom.uuid

    expect(unpublishable_reservation_call(:prepare, operation_id:, entry_ids: [bad])).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => bad, "fields" => ["review_status"] }] }]
    )
    expect(reservation_row_counts).to eq(before)
    expect(InvoiceOperation.where(operation_id:).count).to eq(0)
    expect(Reservation.where(entry_id: bad).count).to eq(0)
    expect(OutboxSnapshot.where(id: bad).count).to eq(0)
    expect(Entry.find(bad).version).to eq(version)
  end

  # The commit releases released_entry, which flips its locked flag and would republish its stored row.
  # Refusing it must roll back everything, and abort must stay possible because it flips only the
  # operation's own provisional entries, which are valid here.
  it "refuses a commit that would release a held entry with a bad stored source, keeps the operation prepared, and still lets it abort" do
    first = SecureRandom.uuid
    unpublishable_reservation_call(:prepare, operation_id: first, entry_ids: [kept_entry, released_entry])
    unpublishable_reservation_call(:commit, operation_id: first)
    second = SecureRandom.uuid
    expect(unpublishable_reservation_call(:prepare, operation_id: second, entry_ids: [kept_entry]).first).to eq(200)
    Entry.find(released_entry).update_column(:source, "legacy")
    before = { audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
               versions: Entry.sum(:version), reservations: Reservation.order(:entry_id, :state).pluck(:entry_id, :state) }

    refused = unpublishable_reservation_call(:commit, operation_id: second)

    expect(refused).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => released_entry, "fields" => ["source"] }] }]
    )
    expect({ audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
             versions: Entry.sum(:version), reservations: Reservation.order(:entry_id, :state).pluck(:entry_id, :state) })
      .to eq(before)
    expect(InvoiceOperation.find_by!(operation_id: second).state).to eq("prepared")

    expect(unpublishable_reservation_call(:abort, operation_id: second).first).to eq(200)
    expect(InvoiceOperation.find_by!(operation_id: second).state).to eq("aborted")
    expect(Reservation.where(entry_id: released_entry).pluck(:state)).to eq(["committed"])
  end

  # Abort unlocks the operation's own provisional entry, so a bad value stored on it after prepare is
  # refused like any other republish, and the abort's deletes roll back with it.
  it "refuses an abort that would unlock a provisional entry with a bad stored source and restores the prepared state" do
    operation_id = SecureRandom.uuid
    expect(unpublishable_reservation_call(:prepare, operation_id:, entry_ids: [kept_entry]).first).to eq(200)
    Entry.find(kept_entry).update_column(:source, "legacy")
    before = { audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
               version: Entry.find(kept_entry).version,
               reservations: Reservation.where(entry_id: kept_entry).pluck(:invoice_id, :state) }

    refused = unpublishable_reservation_call(:abort, operation_id:)

    expect(refused).to eq(
      [409, { "reason" => "unpublishable_entry", "entries" => [{ "entry_id" => kept_entry, "fields" => ["source"] }] }]
    )
    expect({ audits: AuditEvent.count, outbox: OutboxSnapshot.count, receipts: ServiceIdempotencyReceipt.count,
             version: Entry.find(kept_entry).version,
             reservations: Reservation.where(entry_id: kept_entry).pluck(:invoice_id, :state) }).to eq(before)
    expect(before.fetch(:reservations)).to eq([[501, "provisional"]])
    expect(InvoiceOperation.find_by!(operation_id:).state).to eq("prepared")
  end
end

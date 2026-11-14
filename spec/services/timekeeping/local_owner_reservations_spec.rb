require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation access refusals" do
  it "refuses nil, user, ungranted and foreign-company callers of prepare with 401, 403, 403 and 404 before any lock and with nothing changed" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    entry_before = entry.reload.attributes
    baseline = timekeeping_row_counts
    expect(baseline.keys).to include("reservations", "invoice_operations")
    actor = described_class::Actor
    callers = {
      nil => [401, "unauthorized"],
      actor.user(user_id: owner.id, role: "owner") => [403, "forbidden"],
      actor.service(name: "invoices", company_id: company.id, operations: ["reservations.commit"]) => [403, "forbidden"],
      actor.service(name: "invoices", company_id: other_company.id, operations: ["reservations.prepare"]) =>
        [404, "not_found"]
    }

    # "A nil actor, a user actor, a service without `reservations.prepare` and another company's service answer 401, 403, 403 and 404, with nothing changed."
    callers.each do |caller, (status, reason)|
      steps = []
      outcome = described_class.call(
        operation: :prepare, company_id: company.id, generation:, actor: caller,
        params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                  "entry_ids" => [entry.id] },
        checkpoint: ->(step) { steps << step }
      )

      expect(outcome.status).to eq(status)
      expect(outcome.body).to eq("reason" => reason)
      # The rule table is "applied before any lock or read".
      expect(steps).not_to include(:operation_key_locked)
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.attributes).to eq(entry_before)
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "refused callers and stored answers" do
  it "never replays a stored prepare or commit answer to a caller of the same operation_id that access refuses" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    operation_id = SecureRandom.uuid
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
               "entry_ids" => [entry.id] }
    granted = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: %w[reservations.prepare reservations.commit])
    call = ->(operation, actor) { described_class.call(operation:, company_id: company.id, generation:, actor:, params:) }

    before_prepare = timekeeping_row_counts
    call.call(:prepare, granted)
    expect(timekeeping_row_counts["invoice_operations"]).to eq(before_prepare["invoice_operations"] + 1)
    call.call(:commit, granted)
    baseline = timekeeping_row_counts
    entry_before = entry.reload.attributes

    # Same service name and operation_id, but bound to another company, or without the grant:
    # the refusal comes before replay, so neither caller learns the stored answer.
    foreign = described_class::Actor.service(name: "invoices", company_id: other_company.id,
                                             operations: %w[reservations.prepare reservations.commit])
    ungranted = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.abort"])
    %i[prepare commit].each do |operation|
      expect(call.call(operation, foreign).body).to eq("reason" => "not_found")
      expect(call.call(operation, foreign).status).to eq(404)
      expect(call.call(operation, ungranted).body).to eq("reason" => "forbidden")
      expect(call.call(operation, ungranted).status).to eq(403)
    end
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.attributes).to eq(entry_before)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation rollback at an injected failure" do
  def reservation_call(operation, company:, generation:, actor:, invoice:, operation_id:, entry_ids: nil, checkpoint: ->(_step) { })
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    params.merge!("disposition" => "active", "entry_ids" => entry_ids) if operation == :prepare
    described_class.call(operation:, company_id: company.id, generation:, actor:, params:, checkpoint:)
  end

  # "A failure injected after the reservation write leaves no reservation, operation, outbox row or receipt"
  it "a failure injected at reservations_written, outbox_written or receipt_written leaves every write table count and entry version at baseline" do
    expect(TIMEKEEPING_WRITE_TABLES).to include("reservations", "invoice_operations")
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    injected = Class.new(StandardError)

    %i[reservations_written outbox_written].each do |step|
      expect(described_class::STEPS).to include(step)
      baseline = timekeeping_row_counts
      version = entry.reload.version
      expect {
        reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id: SecureRandom.uuid,
                                   entry_ids: [entry.id], checkpoint: ->(seen) { raise injected if seen == step })
      }.to raise_error(injected)
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.version).to eq(version)
    end

    operation_id = SecureRandom.uuid
    prepared = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    expect(prepared.status).to be_between(200, 299)
    expect(described_class::STEPS).to include(:receipt_written)
    baseline = timekeeping_row_counts
    version = entry.reload.version
    expect {
      reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:,
                                checkpoint: ->(seen) { raise injected if seen == :receipt_written })
    }.to raise_error(injected)
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation retry at a stale generation" do
  def reservation_call(operation, company:, generation:, actor:, invoice:, operation_id:, entry_ids: nil)
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    params.merge!("disposition" => "active", "entry_ids" => entry_ids) if operation == :prepare
    described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
  end

  # "The generation check comes before replay, so a stale generation always gets 409 and changes nothing."
  it "a prepare and a commit retried at a stale generation after their answers are stored answer 409 stale_generation and change no count" do
    stored_generation = prepare_local_ownership!.generation
    generation = stored_generation.to_s
    stale = (stored_generation + 1).to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    operation_id = SecureRandom.uuid

    prepared = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    expect(prepared.status).to be_between(200, 299)
    expect(timekeeping_row_counts["invoice_operations"]).to eq(1)
    baseline = timekeeping_row_counts
    stale_prepare = reservation_call(:prepare, company:, generation: stale, actor:, invoice:, operation_id:,
                                               entry_ids: [entry.id])
    expect(stale_prepare.status).to eq(409)
    expect(stale_prepare.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(baseline)

    committed = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
    expect(committed.status).to be_between(200, 299)
    baseline = timekeeping_row_counts
    version = entry.reload.version
    stale_commit = reservation_call(:commit, company:, generation: stale, actor:, invoice:, operation_id:)
    expect(stale_commit.status).to eq(409)
    expect(stale_commit.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation replay at the stored generation" do
  def reservation_call(operation, company:, generation:, actor:, invoice:, operation_id:, entry_ids: nil)
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    params.merge!("disposition" => "active", "entry_ids" => entry_ids) if operation == :prepare
    described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
  end

  # "Replay the stored answer: the operation row for prepare, the receipt for the other operations."
  it "a prepare and a commit repeated at the stored generation replay their answers with no second row or version" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    operation_id = SecureRandom.uuid

    first_prepare = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    after_prepare = timekeeping_row_counts
    version = entry.reload.version
    again = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:, entry_ids: [entry.id])
    expect(again.status).to eq(first_prepare.status)
    expect(again.body).to eq(first_prepare.body)
    expect(timekeeping_row_counts).to eq(after_prepare)
    expect(entry.reload.version).to eq(version)

    first_commit = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
    expect(first_commit.status).to be_between(200, 299)
    after_commit = timekeeping_row_counts
    expect(after_commit["idempotency_records"]).to eq(after_prepare["idempotency_records"] + 1)
    again_commit = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
    expect(again_commit.status).to eq(first_commit.status)
    expect(again_commit.body).to eq(first_commit.body)
    expect(timekeeping_row_counts).to eq(after_commit)
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation lock flag flips" do
  def reservation_call(operation, company:, generation:, actor:, invoice:, operation_id:, entry_ids: nil)
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    params.merge!("disposition" => "active", "entry_ids" => entry_ids) if operation == :prepare
    described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
  end

  def reserved?(entry)
    Timekeeping::LocalEntry.with_reserved.find_by!(company_id: entry.company_id, id: entry.id).reserved
  end

  # "So prepare flips the flag from false to true. Committing a provisional reservation changes nothing visible, with no new version."
  it "prepare writes one version, audit and outbox row per flipped entry and a promotion-only commit writes none" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entries = %w[first second].map do |note|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note:, bill_status: "unbilled")
    end
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    operation_id = SecureRandom.uuid
    versions = entries.map { |entry| entry.reload.version }
    expect(entries.map { |entry| reserved?(entry) }).to eq([false, false])
    baseline = timekeeping_row_counts

    prepared = reservation_call(:prepare, company:, generation:, actor:, invoice:, operation_id:,
                                          entry_ids: entries.map(&:id))
    expect(prepared.status).to be_between(200, 299)
    expect(entries.map { |entry| entry.reload.version }).to eq(versions.map { |version| version + 1 })
    expect(entries.map { |entry| reserved?(entry) }).to eq([true, true])
    after_prepare = timekeeping_row_counts
    expect(after_prepare["entry_audits"]).to eq(baseline["entry_audits"] + 2)
    expect(after_prepare["entry_outbox_items"]).to eq(baseline["entry_outbox_items"] + 2)
    expect(after_prepare["invoice_operations"]).to eq(baseline["invoice_operations"] + 1)
    expect(after_prepare["reservations"]).to eq(baseline["reservations"] + 2)

    committed = reservation_call(:commit, company:, generation:, actor:, invoice:, operation_id:)
    expect(committed.status).to be_between(200, 299)
    expect(entries.map { |entry| entry.reload.version }).to eq(versions.map { |version| version + 1 })
    expect(entries.map { |entry| reserved?(entry) }).to eq([true, true])
    after_commit = timekeeping_row_counts
    expect(after_commit["entry_audits"]).to eq(after_prepare["entry_audits"])
    expect(after_commit["entry_outbox_items"]).to eq(after_prepare["entry_outbox_items"])
    expect(after_commit["reservations"]).to eq(after_prepare["reservations"])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation abort beside another invoice's hold" do
  def reservation_call(operation, company:, generation:, actor:, invoice:, operation_id:, entry_ids: nil)
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    params.merge!("disposition" => "active", "entry_ids" => entry_ids) if operation == :prepare
    described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
  end

  # "Abort flips the flag back to false only when no reservation is left."
  it "abort of invoice B on an entry invoice A still holds keeps the entry locked and writes no version, audit or outbox row" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice_a = create(:invoice, company:, client: project.client)
    invoice_b = create(:invoice, company:, client: project.client)
    held = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                           work_date: Date.current, duration: 30.0, note: "held", bill_status: "unbilled")
    free = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                           work_date: Date.current, duration: 30.0, note: "free", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit", "reservations.abort"])
    operation_a = SecureRandom.uuid
    reservation_call(:prepare, company:, generation:, actor:, invoice: invoice_a, operation_id: operation_a, entry_ids: [held.id])
    reservation_call(:commit, company:, generation:, actor:, invoice: invoice_a, operation_id: operation_a)
    operation_b = SecureRandom.uuid
    reservation_call(:prepare, company:, generation:, actor:, invoice: invoice_b, operation_id: operation_b, entry_ids: [free.id])
    held_version = held.reload.version
    free_version = free.reload.version
    before = timekeeping_row_counts

    aborted = reservation_call(:abort, company:, generation:, actor:, invoice: invoice_b, operation_id: operation_b)

    expect(aborted.status).to be_between(200, 299)
    expect(held.reload.version).to eq(held_version)
    expect(Timekeeping::LocalEntry.with_reserved.find_by!(company_id: company.id, id: held.id).reserved).to be(true)
    # The entry only invoice B held loses its last reservation, so it is the one flip.
    expect(free.reload.version).to eq(free_version + 1)
    after = timekeeping_row_counts
    expect(after["entry_audits"]).to eq(before["entry_audits"] + 1)
    expect(after["entry_outbox_items"]).to eq(before["entry_outbox_items"] + 1)
  end

  # Invoice A keeps a retained committed reservation on the entry, so invoice B
  # can still claim it with a provisional row; aborting B leaves A's row, so
  # the flag never flips.
  it "abort of invoice B's claim on an entry invoice A retains keeps it locked and writes no version, audit or outbox row" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice_a = create(:invoice, company:, client: project.client)
    invoice_b = create(:invoice, company:, client: project.client)
    held = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                           work_date: Date.current, duration: 30.0, note: "held", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit", "reservations.abort"])
    operation_a = SecureRandom.uuid
    prepared_a = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice_a.id, "operation_id" => operation_a, "disposition" => "retained",
                "entry_ids" => [held.id] }
    )
    expect(prepared_a.status).to eq(200)
    expect(reservation_call(:commit, company:, generation:, actor:, invoice: invoice_a,
                                     operation_id: operation_a).status).to eq(200)
    operation_b = SecureRandom.uuid
    expect(reservation_call(:prepare, company:, generation:, actor:, invoice: invoice_b, operation_id: operation_b,
                                      entry_ids: [held.id]).status).to eq(200)
    held_version = held.reload.version
    before = timekeeping_row_counts

    aborted = reservation_call(:abort, company:, generation:, actor:, invoice: invoice_b, operation_id: operation_b)

    expect(aborted.status).to eq(200)
    expect(Timekeeping::LocalEntry.with_reserved.find_by!(company_id: company.id, id: held.id).reserved).to be(true)
    expect(held.reload.version).to eq(held_version)
    after = timekeeping_row_counts
    expect(after["entry_audits"]).to eq(before["entry_audits"])
    expect(after["entry_outbox_items"]).to eq(before["entry_outbox_items"])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation keys per service and company" do
  def reservation_call(operation, company:, generation:, actor:, invoice:, operation_id:, entry_ids: nil)
    params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    params.merge!("disposition" => "active", "entry_ids" => entry_ids) if operation == :prepare
    described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
  end

  def seeded_invoice_entry
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    [company, invoice, entry]
  end

  # "The same operation_id from two services, or from two companies, gives separate operation rows and receipts."
  it "the same operation_id from two services and from two companies gives separate operation rows and receipts" do
    generation = prepare_local_ownership!.generation.to_s
    grants = ["reservations.prepare", "reservations.commit"]
    operation_id = SecureRandom.uuid
    company, invoice_a, entry_a = seeded_invoice_entry
    project_b = create(:project, client: create(:client, company:))
    invoice_b = create(:invoice, company:, client: project_b.client)
    entry_b = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: entry_a.user_id, project_id: project_b.id,
                                              work_date: Date.current, duration: 30.0, note: "b", bill_status: "unbilled")
    other_company, other_invoice, other_entry = seeded_invoice_entry
    calls = [
      [company, invoice_a, entry_a, described_class::Actor.service(name: "invoices", company_id: company.id, operations: grants)],
      [company, invoice_b, entry_b, described_class::Actor.service(name: "agents", company_id: company.id, operations: grants)],
      [other_company, other_invoice, other_entry,
       described_class::Actor.service(name: "invoices", company_id: other_company.id, operations: grants)]
    ]
    baseline = timekeeping_row_counts

    calls.each do |owner_company, invoice, entry, actor|
      prepared = reservation_call(:prepare, company: owner_company, generation:, actor:, invoice:, operation_id:,
                                            entry_ids: [entry.id])
      expect(prepared.status).to be_between(200, 299)
    end
    expect(timekeeping_row_counts["invoice_operations"]).to eq(baseline["invoice_operations"] + 3)

    calls.each do |owner_company, invoice, _entry, actor|
      committed = reservation_call(:commit, company: owner_company, generation:, actor:, invoice:, operation_id:)
      expect(committed.status).to be_between(200, 299)
    end
    after = timekeeping_row_counts
    expect(after["idempotency_records"]).to eq(baseline["idempotency_records"] + 3)
    expect(after["reservations"]).to eq(baseline["reservations"] + 3)
    calls.each do |_owner_company, _invoice, entry, _actor|
      expect(Timekeeping::LocalEntry.with_reserved.find_by!(company_id: entry.company_id, id: entry.id).reserved).to be(true)
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation access refusals" do
  # "A nil actor answers `unauthorized`. A user actor, or a service without the operation, answers `forbidden`. A service bound to another company answers `not_found`."
  it "a nil actor, a user, a service without reservations.prepare and another company's service answer 401, 403, 403 and 404 with nothing changed" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    refused = {
      nil => [401, "unauthorized"],
      described_class::Actor.user(user_id: owner.id, role: "owner") => [403, "forbidden"],
      described_class::Actor.service(name: "invoices", company_id: company.id,
                                     operations: ["reservations.commit", "entries.import"]) => [403, "forbidden"],
      described_class::Actor.service(name: "invoices", company_id: other_company.id,
                                     operations: ["reservations.prepare"]) => [404, "not_found"]
    }
    baseline = timekeeping_row_counts
    version = entry.reload.version

    refused.each do |actor, (status, reason)|
      steps = []
      outcome = described_class.call(
        operation: :prepare, company_id: company.id, generation:, actor:,
        params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                  "entry_ids" => [entry.id] },
        checkpoint: ->(step) { steps << step }
      )
      expect(outcome.status).to eq(status)
      expect(outcome.body).to eq("reason" => reason)
      expect(steps).not_to include(:operation_key_locked)
      expect(timekeeping_row_counts).to eq(baseline)
      expect(entry.reload.version).to eq(version)
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "unpublishable reservation flip" do
  it "a prepare that would flip an unpublishable entry answers 422 unpublishable_entry with its id and field and writes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    # A source outside the snapshot contract's list is a stored value the
    # projection refuses, so publishing this entry's flip would stall the relay.
    entry.update_columns(source: "legacy")
    version_before = entry.reload.version
    baseline = timekeeping_row_counts
    actor = Timekeeping::LocalOwner::Actor.service(name: "invoices", company_id: company.id,
                                                   operations: ["reservations.prepare"])

    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )

    # "A flipped entry that fails `EntryOutbox.invalid_fields` refuses the whole operation with 422
    # `unpublishable_entry`, listing entry ids and field names."
    expect(outcome.status).to eq(422)
    expect(outcome.body["reason"]).to eq("unpublishable_entry")
    listed = JSON.generate(outcome.body)
    expect(listed).to include(entry.id.to_s)
    expect(listed).to include("source")
    expect(listed).not_to include("legacy")
    # "Nothing is written, as `Invoices::PreparedReservations` already does."
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version_before)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation access across companies" do
  # "A service bound to another company answers `not_found`."
  it "a service bound to another company answers not_found on prepare, takes no lock and changes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    baseline = timekeeping_row_counts
    version_before = entry.reload.version
    foreign_service = described_class::Actor.service(name: "invoices", company_id: other_company.id,
                                                     operations: ["reservations.prepare"])
    steps = []

    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor: foreign_service,
      params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [entry.id] },
      checkpoint: ->(step) { steps << step }
    )

    expect(outcome.status).to eq(404)
    expect(outcome.body).to eq("reason" => "not_found")
    # The company check runs "from a rule table, applied before any lock or read".
    expect(steps).not_to include(:operation_key_locked)
    expect(timekeeping_row_counts).to eq(baseline)
    expect(baseline.keys).to include("reservations", "invoice_operations")
    expect(entry.reload.version).to eq(version_before)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation keys per company" do
  # "The same operation_id from two services, or from two companies, gives separate operation rows and receipts."
  it "the same operation_id from two companies gives separate operation rows and service receipts" do
    generation = prepare_local_ownership!.generation.to_s
    operation_id = SecureRandom.uuid
    companies = Array.new(2) { create(:company) }
    companies.each do |company|
      owner = timekeeping_member(company, "owner")
      project = create(:project, client: create(:client, company:))
      invoice = create(:invoice, company:, client: project.client)
      entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                              work_date: Date.current, duration: 30.0, note: "n",
                                              bill_status: "unbilled")
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: ["reservations.prepare", "reservations.commit"])

      prepared = described_class.call(
        operation: :prepare, company_id: company.id, generation:, actor:,
        params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                  "entry_ids" => [entry.id] }
      )
      expect(prepared.status).to eq(200)
      committed = described_class.call(
        operation: :commit, company_id: company.id, generation:, actor:,
        params: { "invoice_id" => invoice.id, "operation_id" => operation_id }
      )
      expect(committed.status).to eq(200)
      expect(entry.reload.attributes.fetch("version")).to be > 0
    end

    connection = ActiveRecord::Base.connection
    operation_companies = connection.select_values(
      ActiveRecord::Base.sanitize_sql_array(["SELECT company_id FROM invoice_operations WHERE operation_id = ?", operation_id])
    )
    expect(operation_companies.map(&:to_i)).to match_array(companies.map(&:id))

    receipts = connection.select_all(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT company_id, actor_id, actor_name FROM idempotency_records WHERE actor_type = 'service' AND key = ?",
         operation_id]
      )
    ).to_a
    expect(receipts.map { |row| row["company_id"].to_i }).to match_array(companies.map(&:id))
    expect(receipts.map { |row| row["actor_id"] }).to all(be_nil)
    expect(receipts.map { |row| row["actor_name"] }).to all(eq("invoices"))
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "commit across companies" do
  # "Every local query filters by `company_id`." A commit in company B must not find company A's operation.
  it "a commit sent by another company's service for a prepared operation_id answers not_found and leaves that operation prepared" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    operation_id = SecureRandom.uuid
    prepared = described_class.call(
      operation: :prepare, company_id: company.id, generation:,
      actor: described_class::Actor.service(name: "invoices", company_id: company.id,
                                            operations: ["reservations.prepare"]),
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    expect(prepared.status).to eq(200)
    baseline = timekeeping_row_counts
    version_after_prepare = entry.reload.version

    outcome = described_class.call(
      operation: :commit, company_id: other_company.id, generation:,
      actor: described_class::Actor.service(name: "invoices", company_id: other_company.id,
                                            operations: ["reservations.commit"]),
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id }
    )

    expect(outcome.status).to eq(404)
    expect(outcome.body).to eq("reason" => "not_found")
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version_after_prepare)
    connection = ActiveRecord::Base.connection
    state = connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT state FROM invoice_operations WHERE company_id = ? AND operation_id = ?", company.id, operation_id]
      )
    )
    expect(state).to eq("prepared")
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "foreign entry ids in prepare" do
  # "`current` holds only reservations on the company's kept, locked entries, so foreign or discarded ids
  # come back as the decision's not_found reason, never as a conflict."
  it "a prepare naming another company's reserved entry reports it as not_found, never as held on another invoice, and changes nothing" do
    generation = prepare_local_ownership!.generation.to_s
    company_a = create(:company)
    company_b = create(:company)
    owner_a = timekeeping_member(company_a, "owner")
    project_a = create(:project, client: create(:client, company: company_a))
    invoice_a = create(:invoice, company: company_a, client: project_a.client)
    foreign_entry = Timekeeping::LocalEntry.create!(company_id: company_a.id, user_id: owner_a.id,
                                                    project_id: project_a.id, work_date: Date.current,
                                                    duration: 30.0, note: "a", bill_status: "unbilled")
    reserved = described_class.call(
      operation: :prepare, company_id: company_a.id, generation:,
      actor: described_class::Actor.service(name: "invoices", company_id: company_a.id,
                                            operations: ["reservations.prepare"]),
      params: { "invoice_id" => invoice_a.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [foreign_entry.id] }
    )
    expect(reserved.status).to eq(200)
    project_b = create(:project, client: create(:client, company: company_b))
    invoice_b = create(:invoice, company: company_b, client: project_b.client)
    baseline = timekeeping_row_counts
    version_before = foreign_entry.reload.version

    outcome = described_class.call(
      operation: :prepare, company_id: company_b.id, generation:,
      actor: described_class::Actor.service(name: "invoices", company_id: company_b.id,
                                            operations: ["reservations.prepare"]),
      params: { "invoice_id" => invoice_b.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [foreign_entry.id] }
    )

    expect(outcome.status).to be_between(400, 499)
    reasons = Array(outcome.body["conflicts"]).map { |conflict| conflict["reason"] }
    expect(reasons).not_to include("on_another_invoice", "provisional_elsewhere")
    expect([outcome.body["reason"], *reasons]).to include("not_found")
    expect(outcome.body.to_json).not_to include(invoice_a.id.to_s) if outcome.body["conflicts"].nil?
    expect(timekeeping_row_counts).to eq(baseline)
    expect(foreign_entry.reload.version).to eq(version_before)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation prepare flips" do
  # "Prepare flips locked from false to true; commit adds no version; abort flips it back to false only when no reservation remains"
  it "prepare flips each unreserved entry to locked with exactly one version, audit row and outbox row" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entries = %w[first second].map do |note|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note:, bill_status: "unbilled")
    end
    versions = entries.to_h { |entry| [entry.id, entry.reload.version] }
    expect(Timekeeping::LocalEntry.with_reserved.where(id: entries.map(&:id)).map(&:reserved)).to all(be(false))
    baseline = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare"])

    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => entries.map(&:id) }
    )

    expect(outcome.status).to eq(200)
    expect(outcome.body["state"]).to eq("prepared")
    entries.each do |entry|
      expect(entry.reload.version).to eq(versions.fetch(entry.id) + 1)
      expect(Timekeeping::LocalEntry.with_reserved.find(entry.id).reserved).to be(true)
    end
    after = timekeeping_row_counts
    expect(after["entry_audits"] - baseline["entry_audits"]).to eq(2)
    expect(after["entry_outbox_items"] - baseline["entry_outbox_items"]).to eq(2)
    expect(after["reservations"] - baseline["reservations"]).to eq(2)
    expect(after["invoice_operations"] - baseline["invoice_operations"]).to eq(1)
    expect(after["entries"]).to eq(baseline["entries"])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation commit of a provisional set" do
  # "Committing a provisional reservation changes nothing visible, with no new version."
  it "commit of a provisional set keeps the entry locked and writes no version, audit or outbox row but stores one service receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    operation_id = SecureRandom.uuid
    prepared = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    expect(prepared.status).to eq(200)
    version = entry.reload.version
    baseline = timekeeping_row_counts

    committed = described_class.call(
      operation: :commit, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id }
    )

    expect(committed.status).to eq(200)
    expect(entry.reload.version).to eq(version)
    expect(Timekeeping::LocalEntry.with_reserved.find(entry.id).reserved).to be(true)
    after = timekeeping_row_counts
    expect(after["entry_audits"]).to eq(baseline["entry_audits"])
    expect(after["entry_outbox_items"]).to eq(baseline["entry_outbox_items"])
    expect(after["reservations"]).to eq(baseline["reservations"])
    expect(after["idempotency_records"]).to eq(baseline["idempotency_records"] + 1)
    # "Service receipts are written with `actor_type "service"`, a nil `actor_id` and `actor_name` = service name."
    receipt = ActiveRecord::Base.connection.select_one(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT actor_type, actor_id, actor_name FROM idempotency_records WHERE company_id = ? AND key = ?",
         company.id, operation_id]
      )
    )
    expect(receipt).to eq("actor_type" => "service", "actor_id" => nil, "actor_name" => "invoices")
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation commit releasing a dropped entry" do
  # "A commit that releases an entry's last reservation unlocks it with exactly one version, audit and outbox row"
  it "a commit with no entries in its body releases the entry the stored desired set dropped with exactly one version, audit and outbox row" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    kept, dropped = %w[kept dropped].map do |note|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note:, bill_status: "unbilled")
    end
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    run = lambda do |operation, params|
      described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
    end
    first = SecureRandom.uuid
    expect(run.call(:prepare, { "invoice_id" => invoice.id, "operation_id" => first, "disposition" => "active",
                                "entry_ids" => [kept.id, dropped.id] }).status).to eq(200)
    expect(run.call(:commit, { "invoice_id" => invoice.id, "operation_id" => first }).status).to eq(200)
    second = SecureRandom.uuid
    expect(run.call(:prepare, { "invoice_id" => invoice.id, "operation_id" => second, "disposition" => "active",
                                "entry_ids" => [kept.id] }).status).to eq(200)
    kept_version = kept.reload.version
    dropped_version = dropped.reload.version
    expect(Timekeeping::LocalEntry.with_reserved.find(dropped.id).reserved).to be(true)
    baseline = timekeeping_row_counts

    outcome = run.call(:commit, { "invoice_id" => invoice.id, "operation_id" => second })

    expect(outcome.status).to eq(200)
    expect(Timekeeping::LocalEntry.with_reserved.find(dropped.id).reserved).to be(false)
    expect(dropped.reload.version).to eq(dropped_version + 1)
    expect(Timekeeping::LocalEntry.with_reserved.find(kept.id).reserved).to be(true)
    expect(kept.reload.version).to eq(kept_version)
    after = timekeeping_row_counts
    expect(after["entry_audits"] - baseline["entry_audits"]).to eq(1)
    expect(after["entry_outbox_items"] - baseline["entry_outbox_items"]).to eq(1)
    audited = ActiveRecord::Base.connection.select_values(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT entry_id FROM entry_audits WHERE company_id = ? ORDER BY id DESC LIMIT 1", company.id]
      )
    )
    expect(audited).to eq([dropped.id])
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation abort" do
  # "Abort flips the flag back to false only when no reservation is left."
  it "abort of invoice B on an entry invoice A still holds keeps it locked and writes no version, audit or outbox row, while an abort leaving no reservation unlocks it" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice_a = create(:invoice, company:, client: project.client)
    invoice_b = create(:invoice, company:, client: project.client)
    held = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                           work_date: Date.current, duration: 30.0, note: "held", bill_status: "unbilled")
    free = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                           work_date: Date.current, duration: 30.0, note: "free", bill_status: "unbilled")
    actor = described_class::Actor.service(
      name: "invoices", company_id: company.id,
      operations: ["reservations.prepare", "reservations.commit", "reservations.abort"]
    )
    run = lambda do |operation, params|
      described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
    end
    op_a = SecureRandom.uuid
    expect(run.call(:prepare, { "invoice_id" => invoice_a.id, "operation_id" => op_a, "disposition" => "active",
                                "entry_ids" => [held.id] }).status).to eq(200)
    expect(run.call(:commit, { "invoice_id" => invoice_a.id, "operation_id" => op_a }).status).to eq(200)
    op_b = SecureRandom.uuid
    expect(run.call(:prepare, { "invoice_id" => invoice_b.id, "operation_id" => op_b, "disposition" => "active",
                                "entry_ids" => [free.id] }).status).to eq(200)
    held_version = held.reload.version
    free_version = free.reload.version
    baseline = timekeeping_row_counts

    expect(run.call(:abort, { "invoice_id" => invoice_b.id, "operation_id" => op_b }).status).to eq(200)

    expect(Timekeeping::LocalEntry.with_reserved.find(held.id).reserved).to be(true)
    expect(held.reload.version).to eq(held_version)
    expect(Timekeeping::LocalEntry.with_reserved.find(free.id).reserved).to be(false)
    expect(free.reload.version).to eq(free_version + 1)
    after = timekeeping_row_counts
    expect(after["entry_audits"] - baseline["entry_audits"]).to eq(1)
    expect(after["entry_outbox_items"] - baseline["entry_outbox_items"]).to eq(1)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation status map" do
  # "Add `reservations.yml` errors to the status map (conflict 409, unresolved_operation 409, unpublishable_entry 422)."
  it "STATUS maps the reservation errors and keeps the entry errors" do
    expect(described_class::STATUS).to include(
      conflict: 409, unresolved_operation: 409, unpublishable_entry: 422,
      stale_generation: 409, not_found: 404, unauthorized: 401, forbidden: 403,
      idempotency_key_required: 422, invalid_request: 400
    )
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner::ServiceAccess, "route operations" do
  # "A grant for one route never admits another. A spec pins the map."
  it "ServiceAccess pins the route to qualified operation map and admits each grant only for its own route" do
    map = described_class::ROUTE_OPERATIONS
    expect(map).to eq(
      prepare: "reservations.prepare", commit: "reservations.commit", abort: "reservations.abort",
      mark_billed: "invoices.mark_billed", detach_entries: Timekeeping::ServiceToken::DETACH_ENTRIES
    )
    expect(Timekeeping::ServiceToken::DETACH_ENTRIES).to eq("agents.detach_entries")
    company_id = 7
    map.each do |granted_route, granted_name|
      actor = Timekeeping::LocalOwner::Actor.service(name: "svc", company_id:, operations: [granted_name])
      map.each_key do |route|
        expected = route == granted_route ? :ok : :forbidden
        expect(described_class.call(actor:, operation: route, company_id:)).to eq(expected),
          "grant #{granted_name} on route #{route}"
      end
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservation access refusals" do
  # "A nil actor answers `unauthorized`. A user actor, or a service without the operation, answers `forbidden`. A service bound to another company answers `not_found`."
  it "prepare from a nil actor, a user, a service without reservations.prepare and another company's service answers 401, 403, 403 and 404 with nothing changed" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    version = entry.reload.version
    baseline = timekeeping_row_counts
    cases = [
      [nil, 401, "unauthorized"],
      [described_class::Actor.user(user_id: owner.id, role: "owner"), 403, "forbidden"],
      [described_class::Actor.service(name: "invoices", company_id: company.id,
                                      operations: ["reservations.commit", "entries.import"]), 403, "forbidden"],
      [described_class::Actor.service(name: "invoices", company_id: other_company.id,
                                      operations: ["reservations.prepare"]), 404, "not_found"]
    ]

    cases.each do |actor, status, reason|
      steps = []
      outcome = described_class.call(
        operation: :prepare, company_id: company.id, generation:, actor:,
        params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                  "entry_ids" => [entry.id] },
        checkpoint: ->(step) { steps << step }
      )
      expect(outcome.status).to eq(status)
      expect(outcome.body).to eq("reason" => reason)
      expect(steps).not_to include(:operation_key_locked)
    end
    expect(timekeeping_row_counts).to eq(baseline)
    expect(baseline.keys).to include("reservations", "invoice_operations")
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: stale prepare retry" do
  it "a prepare retried at a stale generation after its answer is stored answers 409 stale_generation and changes no count" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.prepare"])
    params = { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
               "entry_ids" => [entry.id] }

    first = described_class.call(operation: :prepare, company_id: company.id, generation:, actor:, params:)
    expect(first.status).to eq(200)
    # The stored answer must exist, or this retry cannot tell replay-first from check-first.
    expect(ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM invoice_operations WHERE company_id = #{company.id}"
    ).to_i).to eq(1)

    TimekeepingOwnership.current.update!(generation: ownership.generation + 1)
    baseline = timekeeping_row_counts(tables)
    version = entry.reload.version

    # "The generation check comes before replay, so a stale generation always gets 409 and changes nothing."
    retried = described_class.call(operation: :prepare, company_id: company.id, generation:, actor:, params:)

    expect(retried.status).to eq(409)
    expect(retried.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts(tables)).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: stale commit retry" do
  it "a commit retried at a stale generation after its receipt is stored answers 409 stale_generation and changes no count" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    operation_id = SecureRandom.uuid
    prepared = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    expect(prepared.status).to eq(200)
    commit_params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    committed = described_class.call(operation: :commit, company_id: company.id, generation:, actor:,
                                     params: commit_params)
    expect(committed.status).to eq(200)
    expect(ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM idempotency_records WHERE company_id = #{company.id} AND actor_type = 'service'"
    ).to_i).to eq(1)

    TimekeepingOwnership.current.update!(generation: ownership.generation + 1)
    baseline = timekeeping_row_counts(tables)
    version = entry.reload.version

    # "The generation check comes before replay, so a stale generation always gets 409 and changes nothing."
    retried = described_class.call(operation: :commit, company_id: company.id, generation:, actor:,
                                   params: commit_params)

    expect(retried.status).to eq(409)
    expect(retried.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts(tables)).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: handoff in progress" do
  it "a prepare at the matching generation while handoff_step is set answers stale_generation and writes nothing" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.prepare"])
    ownership.update_column(:handoff_step, "close_admission")
    baseline = timekeeping_row_counts(tables)

    # "It counts only when `Timekeeping::EntryOwner.for` returns `:prepared` and `handoff_step` is nil."
    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )

    expect(outcome.status).to eq(409)
    expect(outcome.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts(tables)).to eq(baseline)
    expect(entry.reload.version).to eq(1)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: injected failure" do
  it "a prepare failing at reservations_written or outbox_written leaves no reservation, operation, outbox row or receipt and no version change" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.prepare"])
    baseline = timekeeping_row_counts(tables)
    injected = Class.new(StandardError)

    # "A failure injected after the reservation write leaves no reservation, operation, outbox row or receipt"
    %i[reservations_written outbox_written].each do |step_name|
      expect(described_class::STEPS).to include(step_name)
      seen = []
      expect {
        described_class.call(
          operation: :prepare, company_id: company.id, generation:, actor:,
          params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                    "entry_ids" => [entry.id] },
          checkpoint: lambda { |step|
            seen << step
            raise injected if step == step_name
          }
        )
      }.to raise_error(injected)

      expect(seen.last).to eq(step_name)
      expect(timekeeping_row_counts(tables)).to eq(baseline)
      expect(entry.reload.version).to eq(1)
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: one operation_id, two services" do
  it "the same operation_id from a second service on another invoice gets its own operation row, never the first service's stored answer" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    first_invoice = create(:invoice, company:, client: project.client)
    second_invoice = create(:invoice, company:, client: project.client)
    first_entry, second_entry = %w[a b].map do |note|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note:, bill_status: "unbilled")
    end
    operation_id = SecureRandom.uuid
    first_service = described_class::Actor.service(name: "invoices", company_id: company.id,
                                                   operations: ["reservations.prepare"])
    second_service = described_class::Actor.service(name: "agents", company_id: company.id,
                                                    operations: ["reservations.prepare"])

    first = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor: first_service,
      params: { "invoice_id" => first_invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [first_entry.id] }
    )
    # With a key missing the service name, this would replay the first answer or answer idempotency_key_reused.
    second = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor: second_service,
      params: { "invoice_id" => second_invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [second_entry.id] }
    )

    # "The same operation_id from two services, or from two companies, gives separate operation rows and receipts."
    expect(first.status).to eq(200)
    expect(second.status).to eq(200)
    rows = ActiveRecord::Base.connection.select_rows(
      "SELECT actor_name, invoice_id FROM invoice_operations " \
      "WHERE company_id = #{company.id} AND operation_id = #{ActiveRecord::Base.connection.quote(operation_id)} " \
      "ORDER BY actor_name"
    )
    expect(rows).to eq([["agents", second_invoice.id], ["invoices", first_invoice.id]])
    expect(second_entry.reload.version).to eq(2)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: one operation_id, two companies" do
  it "the same operation_id and service name from two companies give two operation rows and two service receipts" do
    generation = prepare_local_ownership!.generation.to_s
    operation_id = SecureRandom.uuid
    companies = Array.new(2) { create(:company) }

    companies.each do |company|
      owner = timekeeping_member(company, "owner")
      project = create(:project, client: create(:client, company:))
      invoice = create(:invoice, company:, client: project.client)
      entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                              work_date: Date.current, duration: 30.0, note: "n",
                                              bill_status: "unbilled")
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: ["reservations.prepare", "reservations.commit"])
      prepared = described_class.call(
        operation: :prepare, company_id: company.id, generation:, actor:,
        params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                  "entry_ids" => [entry.id] }
      )
      committed = described_class.call(operation: :commit, company_id: company.id, generation:, actor:,
                                       params: { "invoice_id" => invoice.id, "operation_id" => operation_id })
      expect([prepared.status, committed.status]).to eq([200, 200])
    end

    connection = ActiveRecord::Base.connection
    quoted = connection.quote(operation_id)
    # "The same operation_id from two services, or from two companies, gives separate operation rows and receipts."
    expect(connection.select_values(
      "SELECT company_id FROM invoice_operations WHERE operation_id = #{quoted} ORDER BY company_id"
    )).to eq(companies.map(&:id).sort)
    receipts = connection.select_rows(
      "SELECT company_id, actor_type, actor_id, actor_name FROM idempotency_records " \
      "WHERE key = #{quoted} ORDER BY company_id"
    )
    expect(receipts).to eq(companies.map(&:id).sort.map { |id| [id, "service", nil, "invoices"] })
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: refused callers and stored answers" do
  it "refused callers reusing a stored operation_id get only their refusal, take no lock and change nothing" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    other_company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    params = { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
               "entry_ids" => [entry.id] }
    granted = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: ["reservations.prepare"])
    stored = described_class.call(operation: :prepare, company_id: company.id, generation:, actor: granted, params:)
    expect(stored.status).to eq(200)
    baseline = timekeeping_row_counts(tables)
    version = entry.reload.version

    # "A nil actor answers `unauthorized`. A user actor, or a service without the operation, answers `forbidden`.
    # A service bound to another company answers `not_found`."
    refused = {
      nil => 401,
      described_class::Actor.user(user_id: owner.id, role: "owner") => 403,
      described_class::Actor.service(name: "invoices", company_id: company.id,
                                     operations: ["reservations.commit"]) => 403,
      described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["entries.import"]) => 403,
      described_class::Actor.service(name: "invoices", company_id: other_company.id,
                                     operations: ["reservations.prepare"]) => 404
    }
    refused.each do |actor, status|
      steps = []
      outcome = described_class.call(operation: :prepare, company_id: company.id, generation:, actor:, params:,
                                     checkpoint: ->(step) { steps << step })

      expect(outcome.status).to eq(status)
      expect(outcome.body.keys).to eq(["reason"])
      # "applied before any lock or read"
      expect(steps).not_to include(:operation_key_locked)
      expect(timekeeping_row_counts(tables)).to eq(baseline)
      expect(entry.reload.version).to eq(version)
    end
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: commit delivered twice" do
  it "a commit delivered twice adds no version, audit or outbox row the second time and stores one receipt" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare", "reservations.commit"])
    operation_id = SecureRandom.uuid
    described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    expect(entry.reload.version).to eq(2)
    after_prepare = timekeeping_row_counts(tables)
    commit_params = { "invoice_id" => invoice.id, "operation_id" => operation_id }

    first = described_class.call(operation: :commit, company_id: company.id, generation:, actor:, params: commit_params)
    after_first = timekeeping_row_counts(tables)
    second = described_class.call(operation: :commit, company_id: company.id, generation:, actor:, params: commit_params)

    # "Committing a provisional reservation changes nothing visible, with no new version."
    expect(first.status).to eq(200)
    expect(entry.reload.version).to eq(2)
    expect(after_first).to eq(after_prepare.merge("idempotency_records" => after_prepare["idempotency_records"] + 1))
    # The second delivery replays the stored receipt.
    expect(second.status).to eq(first.status)
    expect(second.body).to eq(first.body)
    expect(timekeeping_row_counts(tables)).to eq(after_first)
    expect(entry.reload.version).to eq(2)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: queued ownership update", committed_data: true do
  it "with an ownership update queued behind a FOR SHARE holder, a prepare answers 409 stale_generation without waiting" do
    tables = %w[entries entry_audits idempotency_records entry_outbox_items reservations invoice_operations]
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id, operations: ["reservations.prepare"])
    baseline = timekeeping_row_counts(tables)
    holding = Queue.new
    release = Queue.new
    holder_pids = []
    updater_pids = []

    holder = committed_data_thread(holder_pids) do
      ApplicationRecord.transaction do
        TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
        holding << true
        release.pop
      end
    end
    holding.pop
    updater = committed_data_thread(updater_pids) do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all("generation = generation")
    end
    sleep 0.01 while updater_pids.empty?

    outcome = nil
    begin
      expect(blocked_by?(updater_pids.first, holder_pids.first)).to be(true)
      # statement_timeout, not lock_timeout: lock_timeout raises the same lock_not_available error a NOWAIT
      # read raises, so a blocking read would pass. A blocking read here fails with a cancelled query instead.
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL statement_timeout = '2s'")
        # "With an ownership update queued, a reservation write answers 409 stale_generation without waiting"
        outcome = described_class.call(
          operation: :prepare, company_id: company.id, generation:, actor:,
          params: { "invoice_id" => invoice.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                    "entry_ids" => [entry.id] }
        )
      end
    ensure
      release << true
      holder.join
      updater.join
    end

    expect(outcome.status).to eq(409)
    expect(outcome.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts(tables)).to eq(baseline)
    expect(entry.reload.version).to eq(1)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "reservations: foreign entry id" do
  it "a prepare naming another company's reserved entry never reports it as a conflict and never touches it" do
    generation = prepare_local_ownership!.generation.to_s
    seeded = Array.new(2) do
      company = create(:company)
      owner = timekeeping_member(company, "owner")
      project = create(:project, client: create(:client, company:))
      invoice = create(:invoice, company:, client: project.client)
      entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                              work_date: Date.current, duration: 30.0, note: "n",
                                              bill_status: "unbilled")
      actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                             operations: ["reservations.prepare"])
      { company:, invoice:, entry:, actor: }
    end
    mine, theirs = seeded
    held = described_class.call(
      operation: :prepare, company_id: theirs[:company].id, generation:, actor: theirs[:actor],
      params: { "invoice_id" => theirs[:invoice].id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [theirs[:entry].id] }
    )
    expect(held.status).to eq(200)
    foreign_before = theirs[:entry].reload.attributes

    outcome = described_class.call(
      operation: :prepare, company_id: mine[:company].id, generation:, actor: mine[:actor],
      params: { "invoice_id" => mine[:invoice].id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [theirs[:entry].id] }
    )

    # "`current` holds only reservations on the company's kept, locked entries, so foreign or discarded ids come
    # back as the decision's not_found reason, never as a conflict."
    reasons = Array(outcome.body["conflicts"]).map { |conflict| conflict["reason"] }
    expect(reasons - ["not_found"]).to be_empty
    expect(theirs[:entry].reload.attributes).to eq(foreign_before)
    expect(ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM reservations WHERE company_id = #{mine[:company].id}"
    ).to_i).to eq(0)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "abort retried after a generation change" do
  it "an abort retried at a stale generation after its receipt is stored answers 409 stale_generation and changes no count" do
    ownership = prepare_local_ownership!
    generation = ownership.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = Timekeeping::LocalOwner::Actor.service(
      name: "invoices", company_id: company.id, operations: ["reservations.prepare", "reservations.abort"]
    )
    operation_id = SecureRandom.uuid
    prepared = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    expect(prepared.status).to be_between(200, 299)
    abort_params = { "invoice_id" => invoice.id, "operation_id" => operation_id }
    aborted = described_class.call(operation: :abort, company_id: company.id, generation:, actor:, params: abort_params)
    expect(aborted.status).to be_between(200, 299)
    # The stored answer must exist, or this retry could not tell replay-first from generation-first.
    expect(ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT COUNT(*) FROM idempotency_records WHERE company_id = ? AND actor_type = 'service' AND key = ?",
         company.id, operation_id]
      )
    ).to_i).to eq(1)

    ownership.reload.update_columns(generation: ownership.generation + 1)
    baseline = timekeeping_row_counts
    version = entry.reload.version

    # "A stale body generation on prepare, commit or abort gives 409 stale_generation and writes nothing, including a retry whose earlier answer is stored"
    retried = described_class.call(operation: :abort, company_id: company.id, generation:, actor:, params: abort_params)

    expect(retried.status).to eq(409)
    expect(retried.body).to eq("reason" => "stale_generation")
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner, "operation insert collision", committed_data: true do
  it "a prepare whose operation insert collides with a row another connection committed runs once more and replays it without a second flip" do
    ownership = prepare_local_ownership!
    generation = ownership.generation
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = Timekeeping::LocalOwner::Actor.service(
      name: "invoices", company_id: company.id, operations: ["reservations.prepare"]
    )
    operation_id = SecureRandom.uuid
    baseline = timekeeping_row_counts
    version = entry.reload.version
    collided = 0
    # Commits the same operation key from another connection after this call's
    # flips are written and before it stores its operation row, once only.
    checkpoint = lambda do |step|
      next unless step == :outbox_written && collided.zero?

      collided += 1
      committed_data_thread do
        ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id, invoice.id, operation_id, "{#{entry.id}}", generation]))
          INSERT INTO invoice_operations (company_id, invoice_id, operation_id, actor_name, state, desired_entry_ids, disposition, generation, created_at)
          VALUES (?, ?, ?, 'invoices', 'prepared', ?, 'active', ?, now())
        SQL
      end.join
    end

    # "A unique violation on either insert rolls back the attempt and runs it once more, as the existing `ReceiptTaken` backstop does."
    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation: generation.to_s, actor:, checkpoint:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )

    expect(collided).to eq(1)
    expect(outcome.status).to be_between(200, 299)
    counts = timekeeping_row_counts
    # Only the other connection's operation row remains: the failed attempt's
    # reservation, version, audit and snapshot rolled back, and the retry
    # replayed the stored row instead of writing again.
    expect(counts).to eq(baseline.merge("invoice_operations" => baseline["invoice_operations"] + 1))
    expect(entry.reload.version).to eq(version)
  end
end

RSpec.describe Timekeeping::LocalOwner, "reservation receipt insert collision", committed_data: true do
  it "a commit whose receipt insert collides with a receipt another connection committed runs once more and replays that receipt" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: %w[reservations.prepare reservations.commit])
    operation_id = SecureRandom.uuid
    prepared = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    expect(prepared.status).to eq(200)
    baseline = timekeeping_row_counts
    version = entry.reload.version
    stored_body = { "reserved" => 7, "released" => 0 }
    fingerprint = Digest::SHA256.hexdigest(JSON.generate("invoice_id" => invoice.id))
    collided = 0
    # Commits the same receipt key from another connection after this call
    # changed its reservations and before it stores its receipt, once only.
    checkpoint = lambda do |step|
      next unless step == :reservations_written && collided.zero?

      collided += 1
      committed_data_thread do
        ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id, operation_id, fingerprint, JSON.generate(stored_body)]))
          INSERT INTO idempotency_records (company_id, actor_type, actor_name, operation, key, fingerprint, status, body, created_at)
          VALUES (?, 'service', 'invoices', 'commit', ?, ?, 200, ?, now())
        SQL
      end.join
    end

    # "A unique violation on either insert rolls back the attempt and runs it once more"
    outcome = described_class.call(operation: :commit, company_id: company.id, generation:, actor:, checkpoint:,
                                   params: { "invoice_id" => invoice.id, "operation_id" => operation_id })

    expect(collided).to eq(1)
    expect(outcome.status).to eq(200)
    expect(outcome.body).to eq(stored_body)
    expect(timekeeping_row_counts).to eq(baseline.merge("idempotency_records" => baseline["idempotency_records"] + 1))
    expect(entry.reload.version).to eq(version)
  end
end

RSpec.describe Timekeeping::LocalOwner, "reservation receipt collision on both attempts" do
  it "a receipt insert that collides on the retry as well raises and leaves every count and version as before" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: %w[reservations.prepare reservations.commit])
    operation_id = SecureRandom.uuid
    described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => invoice.id, "operation_id" => operation_id, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )
    baseline = timekeeping_row_counts
    version = entry.reload.version
    allow(described_class::Receipt).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

    expect {
      described_class.call(operation: :commit, company_id: company.id, generation:, actor:,
                           params: { "invoice_id" => invoice.id, "operation_id" => operation_id })
    }.to raise_error(described_class::ReceiptTaken)

    # One first attempt and exactly one retry.
    expect(described_class::Receipt).to have_received(:create!).twice
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

RSpec.describe Timekeeping::LocalOwner, "reservations written by the invoice coordinator" do
  it "prepare sees a provisional reservation Invoices::PreparedReservations wrote and refuses the entry as provisional_elsewhere" do
    ownership = prepare_local_ownership!
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice_a = create(:invoice, company:, client: project.client)
    invoice_b = create(:invoice, company:, client: project.client)
    entry = Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                            work_date: Date.current, duration: 30.0, note: "n", bill_status: "unbilled")
    coordinator = Invoices::PreparedReservations.new.prepare(Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice_a.id, operation_id: SecureRandom.uuid,
      generation: ownership.generation, disposition: "active", entries: [entry.id]
    ))
    expect(coordinator.state).to eq("prepared")
    baseline = timekeeping_row_counts
    version = entry.reload.version
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare"])

    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation: ownership.generation.to_s, actor:,
      params: { "invoice_id" => invoice_b.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )

    expect(outcome.status).to eq(409)
    expect(outcome.body).to eq("reason" => "conflict",
                               "conflicts" => [{ "entry_id" => entry.id, "reason" => "provisional_elsewhere" }])
    expect(timekeeping_row_counts).to eq(baseline)
    expect(entry.reload.version).to eq(version)
  end
end

RSpec.describe Timekeeping::LocalOwner, "reservation refusals and terminal answers" do
  # Statuses come from contracts/timekeeping/reservations.yml and idempotency.yml;
  # the terminal bodies are the service's answers for a commit or abort the
  # first terminal call already settled.
  it "answers unresolved_operation, idempotency_key_reused, invalid_request and the terminal answers with nothing changed" do
    generation = prepare_local_ownership!.generation.to_s
    company = create(:company)
    owner = timekeeping_member(company, "owner")
    project = create(:project, client: create(:client, company:))
    invoice = create(:invoice, company:, client: project.client)
    other_invoice = create(:invoice, company:, client: project.client)
    entries = %w[first second].map do |note|
      Timekeeping::LocalEntry.create!(company_id: company.id, user_id: owner.id, project_id: project.id,
                                      work_date: Date.current, duration: 30.0, note:, bill_status: "unbilled")
    end
    actor = described_class::Actor.service(
      name: "invoices", company_id: company.id,
      operations: ["reservations.prepare", "reservations.commit", "reservations.abort"]
    )
    run = lambda do |operation, params|
      described_class.call(operation:, company_id: company.id, generation:, actor:, params:)
    end
    prepare_params = lambda do |target, operation_id, entry_ids|
      { "invoice_id" => target.id, "operation_id" => operation_id, "disposition" => "active", "entry_ids" => entry_ids }
    end
    committed_op = SecureRandom.uuid
    expect(run.call(:prepare, prepare_params.call(invoice, committed_op, [entries.first.id])).status).to eq(200)
    expect(run.call(:commit, { "invoice_id" => invoice.id, "operation_id" => committed_op }).status).to eq(200)
    aborted_op = SecureRandom.uuid
    expect(run.call(:prepare, prepare_params.call(other_invoice, aborted_op, [entries.last.id])).status).to eq(200)
    expect(run.call(:abort, { "invoice_id" => other_invoice.id, "operation_id" => aborted_op }).status).to eq(200)
    open_op = SecureRandom.uuid
    expect(run.call(:prepare, prepare_params.call(invoice, open_op, [entries.first.id])).status).to eq(200)

    cases = [
      [:prepare, prepare_params.call(invoice, SecureRandom.uuid, [entries.first.id]), 409,
       { "reason" => "unresolved_operation", "operation_id" => open_op, "retryable" => true }],
      [:prepare, prepare_params.call(invoice, open_op, [entries.last.id]), 422, { "reason" => "idempotency_key_reused" }],
      [:commit, { "invoice_id" => other_invoice.id, "operation_id" => committed_op }, 422,
       { "reason" => "idempotency_key_reused" }],
      [:prepare, prepare_params.call(invoice, "not-a-uuid", [entries.first.id]), 400, { "reason" => "invalid_request" }],
      [:prepare, prepare_params.call(invoice, SecureRandom.uuid, ["x"]), 400, { "reason" => "invalid_request" }],
      [:commit, { "invoice_id" => other_invoice.id, "operation_id" => aborted_op }, 200,
       { "reserved" => 0, "released" => 0 }],
      [:abort, { "invoice_id" => invoice.id, "operation_id" => committed_op }, 200, { "dropped" => 0 }]
    ]
    baseline = timekeeping_row_counts
    versions = entries.map { |entry| entry.reload.version }

    cases.each do |operation, params, status, body|
      outcome = run.call(operation, params)

      expect([operation, outcome.status, outcome.body]).to eq([operation, status, body])
      expect(entries.map { |entry| entry.reload.version }).to eq(versions)
    end
    # The terminal commit and abort store their receipts and change nothing else.
    after = timekeeping_row_counts
    expect(after.except("idempotency_records")).to eq(baseline.except("idempotency_records"))
    expect(after["idempotency_records"]).to eq(baseline["idempotency_records"] + 2)
  end
end

RSpec.describe Timekeeping::LocalOwner, "reservation prepare beside another kept invoice's line" do
  # Lines are written before ownership moves to the prepared store, so no
  # reservation row exists for them, as after a sent invoice's added lines
  # pass admit.
  it "refuses a prepare for entries a sent invoice claims only through a direct or grouped line, and writes nothing" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    user = create(:user, current_workspace_id: company.id)
    direct = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    sent = create(:invoice, company:, client:, status: :sent)
    line = create(:invoice_line_item, invoice: sent, timesheet_entry: direct, rate: 100, quantity: 60)
    grouped = create(:invoice_line_item_time_entry, invoice_line_item: line).timesheet_entry
    InvoiceEntryHolding.where(company_id: company.id, invoice_id: sent.id).delete_all
    draft = create(:invoice, company:, client:, status: :draft)
    [direct, grouped].each do |entry|
      Timekeeping::LocalEntry.create!(id: entry.id, company_id: company.id, user_id: user.id, project_id: project.id,
                                      work_date: Date.current, duration: 60.0, bill_status: "unbilled")
    end
    generation = prepare_local_ownership!.generation.to_s
    baseline = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare"])

    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => draft.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [direct.id, grouped.id] }
    )

    expect(outcome.status).to eq(409)
    expect(outcome.body["reason"]).to eq("conflict")
    expect(outcome.body["conflicts"]).to contain_exactly(
      { "entry_id" => direct.id, "reason" => "on_another_invoice" },
      { "entry_id" => grouped.id, "reason" => "on_another_invoice" }
    )
    expect(timekeeping_row_counts).to eq(baseline)
  end

  it "refuses a restored invoice's prepare for its own retained entry another kept invoice claims through a line" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:, billable: true)
    user = create(:user, current_workspace_id: company.id)
    entry = create(:timesheet_entry, user:, project:, bill_status: "unbilled")
    sent = create(:invoice, company:, client:, status: :sent)
    create(:invoice_line_item, invoice: sent, timesheet_entry: entry, rate: 100, quantity: 60)
    InvoiceEntryHolding.where(company_id: company.id, invoice_id: sent.id).delete_all
    restored = create(:invoice, company:, client:, status: :draft)
    Timekeeping::LocalEntry.create!(id: entry.id, company_id: company.id, user_id: user.id, project_id: project.id,
                                    work_date: Date.current, duration: 60.0, bill_status: "unbilled")
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, company.id, entry.id, restored.id, SecureRandom.uuid, Time.current]))
      INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
      VALUES (?, ?, ?, ?, 'committed', 'retained', ?)
    SQL
    generation = prepare_local_ownership!.generation.to_s
    baseline = timekeeping_row_counts
    actor = described_class::Actor.service(name: "invoices", company_id: company.id,
                                           operations: ["reservations.prepare"])

    outcome = described_class.call(
      operation: :prepare, company_id: company.id, generation:, actor:,
      params: { "invoice_id" => restored.id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                "entry_ids" => [entry.id] }
    )

    expect(outcome.status).to eq(409)
    expect(outcome.body).to eq("reason" => "conflict",
                               "conflicts" => [{ "entry_id" => entry.id, "reason" => "on_another_invoice" }])
    expect(timekeeping_row_counts).to eq(baseline)
  end
end

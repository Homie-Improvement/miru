require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping reservations: another company's invoice id" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A prepare for one company carrying another company's invoice id answers 404 not_found and writes no invoice_operations row"
  # "A foreign invoice id writes nothing in either database."
  # The foreign answer is compared with the answer for an invoice id no company uses, so it cannot reveal that the id exists.
  it "refuses a prepare carrying the other company's invoice id in both directions like an unknown invoice and writes no invoice_operations or reservations row" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    invoices = { first_company => 811, second_company => 822 }
    seeded = invoices.to_h do |company, invoice_id|
      arrange.invoice(company:, invoice_id:)
      user = arrange.user(company:, role: "employee")
      [company, { entry: arrange.entry(company:, user:, project: arrange.project(company:)),
                  token: arrange.service_identity(company:, name: "invoice-boundary",
                                                  operations: %w[prepare commit abort mark_billed]) }]
    end
    prepare = lambda do |company, invoice_id|
      post "/v1/companies/#{company}/reservations/prepare",
           params: { "invoice_id" => invoice_id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                     "entries" => [seeded.fetch(company).fetch(:entry)],
                     "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:token)}",
                      "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      operations_before = InvoiceOperation.count
      reservations_before = Reservation.count

      foreign = prepare.call(requester, invoices.fetch(owner))
      unknown = prepare.call(requester, 990_003)

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(foreign).to eq(unknown)
      expect(InvoiceOperation.count).to eq(operations_before)
      expect(InvoiceOperation.where(invoice_id: invoices.fetch(owner)).count).to eq(0)
      expect(Reservation.count).to eq(reservations_before)
      expect(ServiceIdempotencyReceipt.count).to eq(0)
    end

    # The owner's own prepare of its invoice still succeeds, so the refusal is scoped to the foreign company.
    owner_answer = prepare.call(first_company, invoices.fetch(first_company))
    expect(owner_answer.first).to eq(200)
    expect(InvoiceOperation.where(company_id: first_company, invoice_id: invoices.fetch(first_company)).count).to eq(1)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping reservations: another company's invoice id" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A mark-billed for one company on another company's invoice answers 404 not_found and stores no service_idempotency_receipts row"
  # "A foreign invoice id writes nothing in either database."
  it "refuses a mark-billed of the other company's invoice in both directions like an unknown invoice, billing nothing and storing no receipt" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    invoices = { first_company => 711, second_company => 722 }
    seeded = invoices.to_h do |company, invoice_id|
      [company, { entry: arrange.reserved_entry(company:, invoice_id:, state: "committed"),
                  token: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[mark_billed]) }]
    end
    entry_ids = seeded.values.map { |seed| seed.fetch(:entry) }
    entries_before = Entry.where(id: entry_ids).order(:id).map(&:attributes)
    mark_billed = lambda do |company, invoice_id|
      post "/v1/companies/#{company}/invoices/#{invoice_id}/mark-billed",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:token)}",
                      "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      foreign = mark_billed.call(requester, invoices.fetch(owner))
      unknown = mark_billed.call(requester, 990_001)

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(foreign).to eq(unknown)
      expect(ServiceIdempotencyReceipt.count).to eq(0)
      expect(Entry.where(id: entry_ids).order(:id).map(&:attributes)).to eq(entries_before)
    end

    # The owner can still bill its own invoice afterwards.
    expect(mark_billed.call(second_company, invoices.fetch(second_company))).to eq([200, { "billed" => 1 }])
    expect(ServiceIdempotencyReceipt.where(company_id: first_company).count).to eq(0)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping reservations: another company's invoice id" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A foreign invoice id writes nothing in either database."
  # When the monolith cannot say who owns the invoice, ownership is unknown: the request must be neither
  # accepted as owned nor answered as not owned, and nothing may be written.
  it "answers 503 reference_unavailable and writes nothing on prepare and mark-billed when the reference endpoint cannot answer" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    arrange.invoice(company: other_company, invoice_id: 933)
    entry_id = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    token = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    headers = { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    before = counts.call

    post "/v1/companies/#{company}/reservations/prepare",
         params: { "invoice_id" => 933, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                   "entries" => [entry_id], "generation" => arrange.current_generation }.to_json,
         headers: headers
    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])

    post "/v1/companies/#{company}/invoices/933/mark-billed",
         params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
         headers: headers
    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])

    expect(counts.call).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping reservations: another company's invoice id" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "Timekeeping answers 404 `not_found` for an invoice id the reference does not list for the path company, unless the path company's own `invoice_operations` already hold that `invoice_id` (a hard-deleted invoice keeps its owner in the reservation, lines 440, 589 and 619)."
  # A reference answer that lists the invoice under another company does not list it for the path company,
  # so it must never let the prepare write anything.
  it "never treats an invoice fact naming another company as owned by the path company" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    user = arrange.user(company:, role: "employee")
    project = arrange.project(company:)
    entry_id = arrange.entry(company:, user:, project:)
    token = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    crossed_facts = {
      company_id: company, edit_days: 30, users: [{ id: user, role: "employee" }],
      projects: [], missing_project_ids: [], agents: [], owned_agent_ids: [],
      invoices: [{ id: 944, company_id: other_company }]
    }
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(crossed_facts)
    )

    post "/v1/companies/#{company}/reservations/prepare",
         params: { "invoice_id" => 944, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                   "entries" => [entry_id], "generation" => arrange.current_generation }.to_json,
         headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }

    expect([[404, { "reason" => "not_found" }], [503, { "reason" => "reference_unavailable" }]])
      .to include([response.status, response.parsed_body])
    expect(InvoiceOperation.count).to eq(0)
    expect(Reservation.count).to eq(0)
  end
end

# frozen_string_literal: true
require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping prepare naming another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "refuses a prepare of another company's invoice in both directions, stores nothing a resend could replay, and leaves the owner's prepare under the same operation id unchanged" do
    arrange = timekeeping_arrange
    first = arrange.company
    second = arrange.company
    routes = %w[prepare commit abort mark_billed]
    seeded = { first => 701, second => 702 }.to_h do |company, invoice_id|
      arrange.invoice(company:, invoice_id:)
      entry = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
      [company, { invoice_id:, entry:, service: arrange.service_identity(company:, name: "invoice-boundary", operations: routes) }]
    end
    prepare = lambda do |company, invoice_id, entry, operation_id|
      post "/v1/companies/#{company}/reservations/prepare",
           params: JSON.generate("invoice_id" => invoice_id, "operation_id" => operation_id, "disposition" => "active",
                                 "entries" => [entry], "generation" => arrange.current_generation),
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    [[first, second], [second, first]].each do |requester, owner|
      foreign_invoice = seeded.fetch(owner).fetch(:invoice_id)
      requester_entry = seeded.fetch(requester).fetch(:entry)
      operation_id = SecureRandom.uuid
      operations_before = InvoiceOperation.count
      reservations_before = Reservation.count

      # "A prepare for one company carrying another company's invoice id answers 404 not_found and writes no invoice_operations row"
      expect(prepare.call(requester, foreign_invoice, requester_entry, operation_id)).to eq([404, { "reason" => "not_found" }])
      # "A foreign invoice id writes nothing in either database."
      expect(InvoiceOperation.count).to eq(operations_before)
      expect(InvoiceOperation.where(invoice_id: foreign_invoice).count).to eq(0)
      expect(Reservation.count).to eq(reservations_before)
      expect(arrange.reservations_for(requester_entry)).to eq([])

      # A refusal is not stored, so a resend under the same key is evaluated again and refused again.
      expect(prepare.call(requester, foreign_invoice, requester_entry, operation_id)).to eq([404, { "reason" => "not_found" }])
      expect(InvoiceOperation.count).to eq(operations_before)

      # The owner prepares its own invoice under the same operation id as if no foreign request had come first.
      owner_entry = seeded.fetch(owner).fetch(:entry)
      expect(prepare.call(owner, foreign_invoice, owner_entry, operation_id))
        .to eq([200, { "operation_id" => operation_id, "state" => "prepared",
                       "entries" => [{ "entry_id" => owner_entry, "company_id" => owner }] }])
      expect(InvoiceOperation.where(company_id: owner, invoice_id: foreign_invoice).count).to eq(1)
      expect(InvoiceOperation.where(company_id: requester, invoice_id: foreign_invoice).count).to eq(0)

      abort_body = JSON.generate("invoice_id" => foreign_invoice, "operation_id" => operation_id,
                                 "generation" => arrange.current_generation)
      post "/v1/companies/#{owner}/reservations/abort", params: abort_body,
           headers: { "Authorization" => "Bearer #{seeded.fetch(owner).fetch(:service)}", "Content-Type" => "application/json" }
      expect(response.status).to eq(200)
    end
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping mark-billed naming another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "refuses a mark-billed of another company's invoice in both directions with no receipt on first send or resend, then bills it once for its owner under the same operation id" do
    arrange = timekeeping_arrange
    first = arrange.company
    second = arrange.company
    seeded = { first => 711, second => 712 }.to_h do |company, invoice_id|
      [company, { invoice_id:, entry: arrange.reserved_entry(company:, invoice_id:, state: "committed"),
                  service: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[mark_billed]) }]
    end
    mark_billed = lambda do |company, invoice_id, operation_id|
      post "/v1/companies/#{company}/invoices/#{invoice_id}/mark-billed",
           params: JSON.generate("operation_id" => operation_id, "generation" => arrange.current_generation),
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    [[first, second], [second, first]].each do |requester, owner|
      foreign_invoice = seeded.fetch(owner).fetch(:invoice_id)
      owner_entry = seeded.fetch(owner).fetch(:entry)
      operation_id = SecureRandom.uuid
      receipts_before = ServiceIdempotencyReceipt.count
      # The second round's requester billed its own invoice in the first round, so its receipts are counted
      # from where this round starts.
      requester_receipts_before = ServiceIdempotencyReceipt.where(company_id: requester).count
      versions_before = Entry.sum(:version)

      # "A mark-billed for one company on another company's invoice answers 404 not_found and stores no service_idempotency_receipts row"
      2.times do |attempt|
        expect(mark_billed.call(requester, foreign_invoice, operation_id))
          .to eq([404, { "reason" => "not_found" }]), "attempt #{attempt + 1}"
        expect(ServiceIdempotencyReceipt.count).to eq(receipts_before), "attempt #{attempt + 1}"
        expect(ServiceIdempotencyReceipt.where(company_id: requester).count).to eq(requester_receipts_before)
        # "A foreign invoice id writes nothing in either database."
        expect(Entry.sum(:version)).to eq(versions_before)
        expect(arrange.stored_entry(owner_entry).fetch("bill_status")).to eq("unbilled")
      end

      # The owner's own mark-billed under the same operation id bills once and stores one receipt; a resend replays it.
      expect(mark_billed.call(owner, foreign_invoice, operation_id)).to eq([200, { "billed" => 1 }])
      expect(arrange.stored_entry(owner_entry).fetch("bill_status")).to eq("billed")
      version_after_billing = Entry.find(owner_entry).version
      expect(mark_billed.call(owner, foreign_invoice, operation_id)).to eq([200, { "billed" => 1 }])
      expect(ServiceIdempotencyReceipt.where(company_id: owner, key: operation_id).count).to eq(1)
      expect(ServiceIdempotencyReceipt.where(company_id: requester).count).to eq(requester_receipts_before)
      expect(Entry.find(owner_entry).version).to eq(version_after_billing)
    end
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping invoice ownership while the reference cannot answer" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "answers 503 and writes nothing on prepare and mark-billed of an own invoice while the reference cannot answer, and the same operation ids succeed once it answers again" do
    arrange = timekeeping_arrange
    company = arrange.company
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    arrange.invoice(company:, invoice_id: 721)
    free_entry = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    billable = arrange.reserved_entry(company:, invoice_id: 722, state: "committed")
    send_command = lambda do |path, body|
      post path, params: JSON.generate(body.merge("generation" => arrange.current_generation)),
                 headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    prepare_key = SecureRandom.uuid
    billing_key = SecureRandom.uuid
    prepare_body = { "invoice_id" => 721, "operation_id" => prepare_key, "disposition" => "active", "entries" => [free_entry] }
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    before = counts.call

    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)

    # Ownership that cannot be read is neither "owned" nor "not owned": the request is refused and nothing is stored.
    expect(send_command.call("/v1/companies/#{company}/reservations/prepare", prepare_body))
      .to eq([503, { "reason" => "reference_unavailable" }])
    expect(send_command.call("/v1/companies/#{company}/invoices/722/mark-billed", { "operation_id" => billing_key }))
      .to eq([503, { "reason" => "reference_unavailable" }])
    expect(counts.call).to eq(before)
    expect(arrange.stored_entry(billable).fetch("bill_status")).to eq("unbilled")

    arrange.stub_reference

    # Nothing was stored under either key, so each retry is evaluated as a first attempt.
    expect(send_command.call("/v1/companies/#{company}/reservations/prepare", prepare_body))
      .to eq([200, { "operation_id" => prepare_key, "state" => "prepared",
                     "entries" => [{ "entry_id" => free_entry, "company_id" => company }] }])
    expect(send_command.call("/v1/companies/#{company}/invoices/722/mark-billed", { "operation_id" => billing_key }))
      .to eq([200, { "billed" => 1 }])
    expect(InvoiceOperation.where(company_id: company, invoice_id: 721).count).to eq(1)
    expect(ServiceIdempotencyReceipt.where(company_id: company, key: billing_key).count).to eq(1)
  end
end

# frozen_string_literal: true
require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping reservation prepare naming another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "R1 R7 refuses a prepare naming the other company's invoice in both directions, like an unknown invoice, writing nothing for either company" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    routes = %w[prepare commit abort mark_billed]
    seeded = { first_company => 7101, second_company => 7202 }.to_h do |company, invoice_id|
      arrange.invoice(company:, invoice_id:)
      user = arrange.user(company:, role: "employee")
      [company, { invoice: invoice_id,
                  entry: arrange.entry(company:, user:, project: arrange.project(company:)),
                  service: arrange.service_identity(company:, name: "invoice-boundary", operations: routes) }]
    end
    prepare = lambda do |company, invoice_id, entry_id|
      post "/v1/companies/#{company}/reservations/prepare",
           params: { "invoice_id" => invoice_id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                     "entries" => [entry_id], "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}",
                      "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    # Each owner prepares its own invoice first, so the owner's invoice_operations row exists and must not
    # make the invoice count as the other company's.
    seeded.each do |company, values|
      expect(prepare.call(company, values.fetch(:invoice), values.fetch(:entry)).first).to eq(200)
    end

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      operations_before = InvoiceOperation.where(company_id: [requester, owner]).order(:id).map(&:attributes)
      # reservations has no id column, so its rows are ordered by the columns that name one reservation.
      reservations_before = Reservation.where(company_id: [requester, owner])
        .order(:company_id, :entry_id, :invoice_id, :state).map(&:attributes)
      receipts_before = ServiceIdempotencyReceipt.count

      # "A prepare for one company carrying another company's invoice id answers 404 not_found and writes no invoice_operations row"
      foreign = prepare.call(requester, seeded.fetch(owner).fetch(:invoice), seeded.fetch(requester).fetch(:entry))
      unknown = prepare.call(requester, 990_777, seeded.fetch(requester).fetch(:entry))

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(foreign).to eq(unknown)
      # "A foreign invoice id writes nothing in either database."
      expect(InvoiceOperation.where(company_id: requester, invoice_id: seeded.fetch(owner).fetch(:invoice))).to be_empty
      expect(InvoiceOperation.where(company_id: [requester, owner]).order(:id).map(&:attributes)).to eq(operations_before)
      expect(Reservation.where(company_id: [requester, owner])
        .order(:company_id, :entry_id, :invoice_id, :state).map(&:attributes)).to eq(reservations_before)
      expect(Reservation.where(invoice_id: seeded.fetch(owner).fetch(:invoice)).pluck(:company_id).uniq).to eq([owner])
      expect(ServiceIdempotencyReceipt.count).to eq(receipts_before)
    end
  end
end

# frozen_string_literal: true
require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping mark-billed of another company's held invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "R2 R7 refuses a mark-billed of the other company's invoice in both directions, like an unknown invoice, billing nothing and storing no receipt, then the owner still bills it" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    seeded = { first_company => 7311, second_company => 7322 }.to_h do |company, invoice_id|
      [company, { invoice: invoice_id,
                  entry: arrange.reserved_entry(company:, invoice_id:, state: "committed"),
                  service: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[mark_billed]) }]
    end
    mark_billed = lambda do |company, invoice_id, operation_id = SecureRandom.uuid|
      post "/v1/companies/#{company}/invoices/#{invoice_id}/mark-billed",
           params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}",
                      "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    entry_ids = seeded.values.map { |values| values.fetch(:entry) }
    entries_before = Entry.where(id: entry_ids).order(:id).map(&:attributes)

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      operation_id = SecureRandom.uuid

      # "A mark-billed for one company on another company's invoice answers 404 not_found and stores no service_idempotency_receipts row"
      foreign = mark_billed.call(requester, seeded.fetch(owner).fetch(:invoice), operation_id)
      resent = mark_billed.call(requester, seeded.fetch(owner).fetch(:invoice), operation_id)
      unknown = mark_billed.call(requester, 990_888)

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(resent).to eq(foreign)
      expect(foreign).to eq(unknown)
      expect(ServiceIdempotencyReceipt.where(company_id: [requester, owner])).to be_empty
      expect(Entry.where(id: entry_ids).order(:id).map(&:attributes)).to eq(entries_before)
    end

    # The refused requests left nothing that changes the owners' own answers.
    seeded.each do |company, values|
      expect(mark_billed.call(company, values.fetch(:invoice))).to eq([200, { "billed" => 1 }])
      expect(Entry.find(values.fetch(:entry)).bill_status).to eq("billed")
      expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(1)
    end
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping prepare naming another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A prepare for one company carrying another company's invoice id answers 404 not_found and writes no invoice_operations row"
  # "Both behaviours are pinned by request specs in both directions"
  it "refuses a prepare of the other company's invoice in both directions like an unknown id, writes nothing, and still prepares each owner's own invoice" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    invoices = { first_company => 711, second_company => 722 }
    seeded = invoices.to_h do |company, invoice_id|
      arrange.invoice(company:, invoice_id:)
      user = arrange.user(company:, role: "employee")
      [company, { service: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed]),
                  entry: arrange.entry(company:, user:, project: arrange.project(company:)) }]
    end
    prepare = lambda do |company, invoice_id|
      post "/v1/companies/#{company}/reservations/prepare",
           params: { "invoice_id" => invoice_id, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                     "entries" => [seeded.fetch(company).fetch(:entry)], "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count] }

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      before = counts.call

      foreign = prepare.call(requester, invoices.fetch(owner))
      unknown = prepare.call(requester, 990_001)

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(foreign).to eq(unknown)
      expect(counts.call).to eq(before)
      expect(InvoiceOperation.where(company_id: requester, invoice_id: invoices.fetch(owner)).count).to eq(0)
      expect(arrange.reservations_for(seeded.fetch(requester).fetch(:entry))).to eq([])
    end

    invoices.each do |company, invoice_id|
      status, body = prepare.call(company, invoice_id)
      expect(status).to eq(200)
      expect(body.fetch("state")).to eq("prepared")
      expect(InvoiceOperation.where(company_id: company, invoice_id:).count).to eq(1)
    end
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping mark-billed naming another company's invoice, both directions" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A mark-billed for one company on another company's invoice answers 404 not_found and stores no service_idempotency_receipts row"
  # "Both behaviours are pinned by request specs in both directions"
  it "refuses a mark-billed of the other company's invoice in both directions like an unknown id, stores no receipt, and still bills each owner's invoice once" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    invoices = { first_company => 731, second_company => 742 }
    seeded = invoices.to_h do |company, invoice_id|
      [company, { service: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[mark_billed]),
                  entry: arrange.reserved_entry(company:, invoice_id:, state: "committed") }]
    end
    mark_billed = lambda do |company, invoice_id|
      post "/v1/companies/#{company}/invoices/#{invoice_id}/mark-billed",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    entry_ids = seeded.values.map { |seed| seed.fetch(:entry) }
    entries_before = Entry.where(id: entry_ids).order(:id).map(&:attributes)

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      foreign = mark_billed.call(requester, invoices.fetch(owner))
      unknown = mark_billed.call(requester, 990_003)

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(foreign).to eq(unknown)
      expect(ServiceIdempotencyReceipt.count).to eq(0)
      expect(Entry.where(id: entry_ids).order(:id).map(&:attributes)).to eq(entries_before)
    end

    invoices.each do |company, invoice_id|
      expect(mark_billed.call(company, invoice_id)).to eq([200, { "billed" => 1 }])
      expect(Entry.find(seeded.fetch(company).fetch(:entry)).bill_status).to eq("billed")
      expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(1)
    end
    expect(ServiceIdempotencyReceipt.count).to eq(2)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping prepare of a hard-deleted invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "Timekeeping answers 404 `not_found` for an invoice id the reference does not list for the path company, unless the path company's own `invoice_operations` already hold that `invoice_id` (a hard-deleted invoice keeps its owner in the reservation, lines 440, 589 and 619)."
  it "keeps preparing an invoice the reference no longer lists when the path company's own invoice_operations hold it, and refuses it to another company" do
    arrange = timekeeping_arrange
    owner = arrange.company
    other = arrange.company
    arrange.invoice(company: owner, invoice_id: 751)
    owner_user = arrange.user(company: owner, role: "employee")
    owner_entry = arrange.entry(company: owner, user: owner_user, project: arrange.project(company: owner))
    other_user = arrange.user(company: other, role: "employee")
    other_entry = arrange.entry(company: other, user: other_user, project: arrange.project(company: other))
    services = [owner, other].index_with do |company|
      arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    end
    send_command = lambda do |company, route, body|
      post "/v1/companies/#{company}/reservations/#{route}",
           params: { "generation" => arrange.current_generation }.merge(body).to_json,
           headers: { "Authorization" => "Bearer #{services.fetch(company)}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    first_operation = SecureRandom.uuid
    expect(send_command.call(owner, "prepare", { "invoice_id" => 751, "operation_id" => first_operation,
                                                 "disposition" => "active", "entries" => [owner_entry] }).first).to eq(200)
    expect(send_command.call(owner, "commit", { "invoice_id" => 751, "operation_id" => first_operation }).first).to eq(200)

    # The monolith has hard-deleted invoice 751: its reference lists no invoice for either company.
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return do |request|
      company_id = Integer(request.uri.path[%r{/companies/(\d+)/}, 1], 10)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(company_id:, edit_days: 30, users: [], projects: [], missing_project_ids: [], agents: [],
                            owned_agent_ids: [], invoices: []) }
    end

    release = send_command.call(owner, "prepare", { "invoice_id" => 751, "operation_id" => SecureRandom.uuid,
                                                    "disposition" => "active", "entries" => [] })
    expect(release.first).to eq(200)
    expect(release.last.fetch("state")).to eq("prepared")

    before = [InvoiceOperation.where(company_id: other).count, Reservation.where(company_id: other).count]
    foreign = send_command.call(other, "prepare", { "invoice_id" => 751, "operation_id" => SecureRandom.uuid,
                                                    "disposition" => "active", "entries" => [other_entry] })
    expect(foreign).to eq([404, { "reason" => "not_found" }])
    expect([InvoiceOperation.where(company_id: other).count, Reservation.where(company_id: other).count]).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping invoice ownership while the reference is down" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A foreign invoice id writes nothing in either database."
  # When ownership cannot be read, the request is neither treated as owned nor answered as not owned.
  it "answers 503 reference_unavailable on prepare and mark-billed of an unprepared invoice when the reference cannot answer, and writes nothing" do
    arrange = timekeeping_arrange
    company = arrange.company
    arrange.invoice(company:, invoice_id: 761)
    user = arrange.user(company:, role: "employee")
    entry = arrange.entry(company:, user:, project: arrange.project(company:))
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    headers = { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    before = counts.call

    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)

    post "/v1/companies/#{company}/reservations/prepare",
         params: { "invoice_id" => 761, "operation_id" => SecureRandom.uuid, "disposition" => "active",
                   "entries" => [entry], "generation" => arrange.current_generation }.to_json, headers: headers
    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])

    post "/v1/companies/#{company}/invoices/761/mark-billed",
         params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json, headers: headers
    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])

    expect(counts.call).to eq(before)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping prepare naming another company's invoice, then its owner" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "refuses a foreign prepare in both directions without consuming the operation id, so the owner's prepare under the same id still succeeds" do
    arrange = timekeeping_arrange
    first = arrange.company
    second = arrange.company
    routes = %w[prepare commit abort mark_billed]
    seeded = { first => 711, second => 722 }.to_h do |company, invoice_id|
      arrange.invoice(company:, invoice_id:)
      [company, { invoice: invoice_id,
                  service: arrange.service_identity(company:, name: "invoice-boundary", operations: routes),
                  entry: arrange.entry(company:, user: arrange.user(company:, role: "employee"),
                                       project: arrange.project(company:)) }]
    end
    prepare = lambda do |company, invoice_id, operation_id, entry_id|
      post "/v1/companies/#{company}/reservations/prepare",
           params: JSON.generate("generation" => arrange.current_generation, "invoice_id" => invoice_id,
                                 "operation_id" => operation_id, "disposition" => "active", "entries" => [entry_id]),
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}",
                      "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    [[first, second], [second, first]].each do |requester, owner|
      operation_id = SecureRandom.uuid
      owner_invoice = seeded.fetch(owner).fetch(:invoice)
      requester_entry = seeded.fetch(requester).fetch(:entry)
      operations_before = InvoiceOperation.count
      reservations_before = Reservation.count
      # The second round's requester prepared its own entry in the first round, so the entry's reservations
      # are compared with what this round starts from.
      requester_entry_reservations_before = arrange.reservations_for(requester_entry)

      # "A prepare for one company carrying another company's invoice id answers 404 not_found and writes no invoice_operations row"
      foreign = prepare.call(requester, owner_invoice, operation_id, requester_entry)
      resent = prepare.call(requester, owner_invoice, operation_id, requester_entry)
      unknown = prepare.call(requester, 990_101, SecureRandom.uuid, requester_entry)

      expect(foreign).to eq([404, { "reason" => "not_found" }])
      expect(foreign).to eq(unknown)
      # A refusal is not stored under the key, so a resend is checked again and refused again.
      expect(resent).to eq(foreign)
      # "A foreign invoice id writes nothing in either database."
      expect(InvoiceOperation.count).to eq(operations_before)
      expect(InvoiceOperation.where(company_id: requester, invoice_id: owner_invoice).count).to eq(0)
      expect(Reservation.count).to eq(reservations_before)
      expect(arrange.reservations_for(requester_entry)).to eq(requester_entry_reservations_before)
      expect(arrange.reservations_for(requester_entry).pluck("invoice_id")).not_to include(owner_invoice)

      # The refused request left nothing under the operation id, so the owner's own prepare is a first attempt.
      owner_entry = seeded.fetch(owner).fetch(:entry)
      expect(prepare.call(owner, owner_invoice, operation_id, owner_entry))
        .to eq([200, { "operation_id" => operation_id, "state" => "prepared",
                       "entries" => [{ "entry_id" => owner_entry, "company_id" => owner }] }])
      expect(InvoiceOperation.where(company_id: owner, invoice_id: owner_invoice).count).to eq(1)
      expect(Reservation.count).to eq(reservations_before + 1)
    end
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping mark-billed naming another company's invoice, then its owner" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "answers 404 to a twice-sent foreign mark-billed in both directions, storing no receipt, and the owner's mark-billed under the same operation id still bills" do
    arrange = timekeeping_arrange
    first = arrange.company
    second = arrange.company
    seeded = { first => 811, second => 822 }.to_h do |company, invoice_id|
      [company, { invoice: invoice_id,
                  service: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[mark_billed]),
                  entry: arrange.reserved_entry(company:, invoice_id:, state: "committed") }]
    end
    mark_billed = lambda do |company, invoice_id, operation_id|
      post "/v1/companies/#{company}/invoices/#{invoice_id}/mark-billed",
           params: JSON.generate("operation_id" => operation_id, "generation" => arrange.current_generation),
           headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}",
                      "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    [[first, second], [second, first]].each do |requester, owner|
      operation_id = SecureRandom.uuid
      owner_invoice = seeded.fetch(owner).fetch(:invoice)
      owner_entry = seeded.fetch(owner).fetch(:entry)
      receipts_before = ServiceIdempotencyReceipt.count
      # The second round's requester billed its own invoice in the first round, so its receipts are counted
      # from where this round starts.
      requester_receipts_before = ServiceIdempotencyReceipt.where(company_id: requester).count

      # "A mark-billed for one company on another company's invoice answers 404 not_found and stores no service_idempotency_receipts row"
      2.times do |attempt|
        expect(mark_billed.call(requester, owner_invoice, operation_id))
          .to eq([404, { "reason" => "not_found" }]), "attempt #{attempt + 1}"
        expect(ServiceIdempotencyReceipt.count).to eq(receipts_before), "attempt #{attempt + 1}"
        expect(Entry.find(owner_entry).bill_status).to eq("unbilled")
      end
      expect(mark_billed.call(requester, owner_invoice, operation_id))
        .to eq(mark_billed.call(requester, 990_201, SecureRandom.uuid))

      expect(mark_billed.call(owner, owner_invoice, operation_id)).to eq([200, { "billed" => 1 }])
      expect(Entry.find(owner_entry).bill_status).to eq("billed")
      expect(ServiceIdempotencyReceipt.where(company_id: requester).count).to eq(requester_receipts_before)
      expect(ServiceIdempotencyReceipt.where(company_id: owner, key: operation_id).count).to eq(1)
    end
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping prepare while the reference endpoint is down" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "refuses an own new invoice's prepare with 503 while the reference is down, stores nothing, and prepares it on a retry under the same key once the reference answers" do
    arrange = timekeeping_arrange
    company = arrange.company
    arrange.invoice(company:, invoice_id: 911)
    entry_id = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort])
    operation_id = SecureRandom.uuid
    prepare = lambda do
      post "/v1/companies/#{company}/reservations/prepare",
           params: JSON.generate("generation" => arrange.current_generation, "invoice_id" => 911,
                                 "operation_id" => operation_id, "disposition" => "active", "entries" => [entry_id]),
           headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    before = counts.call

    down = WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)
    # Unknown ownership is neither "owned" (2xx) nor "not owned" (404), and leaves no row that would decide a retry.
    expect(prepare.call).to eq([503, { "reason" => "reference_unavailable" }])
    expect(counts.call).to eq(before)

    WebMock.remove_request_stub(down)
    arrange.stub_reference
    # "A foreign invoice id writes nothing in either database." applies to the refused attempt above; the own
    # invoice's retry must therefore be evaluated as a first attempt, not replayed as a refusal.
    expect(prepare.call).to eq([200, { "operation_id" => operation_id, "state" => "prepared",
                                       "entries" => [{ "entry_id" => entry_id, "company_id" => company }] }])
    expect(InvoiceOperation.where(company_id: company, invoice_id: 911).count).to eq(1)
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping mark-billed of a hard-deleted invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "keeps the own-operations fallback to the path company, so another company's invoice_operations never open mark-billed when the reference lists no invoice" do
    arrange = timekeeping_arrange
    owner = arrange.company
    other = arrange.company
    arrange.invoice(company: owner, invoice_id: 931)
    routes = %w[prepare commit abort mark_billed]
    owner_service = arrange.service_identity(company: owner, name: "invoice-boundary", operations: routes)
    other_service = arrange.service_identity(company: other, name: "invoice-boundary", operations: routes)
    owner_entry = arrange.entry(company: owner, user: arrange.user(company: owner, role: "employee"),
                                project: arrange.project(company: owner))
    send_command = lambda do |company, credential, path, body|
      post "/v1/companies/#{company}#{path}",
           params: JSON.generate({ "generation" => arrange.current_generation }.merge(body)),
           headers: { "Authorization" => "Bearer #{credential}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    operation_id = SecureRandom.uuid
    expect(send_command.call(owner, owner_service, "/reservations/prepare",
                             "invoice_id" => 931, "operation_id" => operation_id, "disposition" => "active",
                             "entries" => [owner_entry]).first).to eq(200)
    expect(send_command.call(owner, owner_service, "/reservations/commit",
                             "invoice_id" => 931, "operation_id" => operation_id).first).to eq(200)

    # The invoice is hard-deleted in the monolith: the reference now lists no invoice for any company.
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return do |request|
      company_id = Integer(request.uri.path[%r{/companies/(\d+)/reference}, 1], 10)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(company_id:, edit_days: 30, users: [], projects: [], missing_project_ids: [],
                            agents: [], owned_agent_ids: [], invoices: []) }
    end

    # "Timekeeping answers 404 `not_found` for an invoice id the reference does not list for the path company,
    # unless the path company's own `invoice_operations` already hold that `invoice_id`"
    receipts_before = ServiceIdempotencyReceipt.count
    foreign = send_command.call(other, other_service, "/invoices/931/mark-billed", "operation_id" => SecureRandom.uuid)
    expect(foreign).to eq([404, { "reason" => "not_found" }])
    expect(ServiceIdempotencyReceipt.count).to eq(receipts_before)
    expect(Entry.find(owner_entry).bill_status).to eq("unbilled")

    own = send_command.call(owner, owner_service, "/invoices/931/mark-billed", "operation_id" => SecureRandom.uuid)
    expect(own).to eq([200, { "billed" => 1 }])
    expect(Entry.find(owner_entry).bill_status).to eq("billed")
  end
end

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping prepare against a crossed reference answer" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  it "never treats an invoice fact naming another company as owned: a crossed reference answer refuses the prepare and writes nothing" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    entry_id = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare])
    # The answer is for the path company, but its only invoice fact names another company as the owner.
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(company_id: company, edit_days: 30, users: [], projects: [], missing_project_ids: [],
                          agents: [], owned_agent_ids: [], invoices: [{ id: 951, company_id: other_company }])
    )
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    before = counts.call

    post "/v1/companies/#{company}/reservations/prepare",
         params: JSON.generate("generation" => arrange.current_generation, "invoice_id" => 951,
                               "operation_id" => SecureRandom.uuid, "disposition" => "active", "entries" => [entry_id]),
         headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }

    # "A foreign invoice id writes nothing in either database."
    expect(response.status).not_to be_between(200, 299)
    expect([[404, { "reason" => "not_found" }], [503, { "reason" => "reference_unavailable" }]])
      .to include([response.status, response.parsed_body])
    expect(counts.call).to eq(before)
    expect(InvoiceOperation.where(company_id: company, invoice_id: 951).count).to eq(0)
  end
end

RSpec.describe "Timekeeping invoice ownership read from a reference answer without invoice facts" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # A monolith that does not send the invoices field says nothing about who owns the invoice, so the request
  # is refused as unavailable rather than answered as not owned or let through as owned.
  it "answers 503 and writes nothing on prepare and mark-billed when the reference answer carries no invoices field" do
    arrange = timekeeping_arrange
    company = arrange.company
    arrange.invoice(company:, invoice_id: 961)
    entry_id = arrange.entry(company:, user: arrange.user(company:, role: "employee"), project: arrange.project(company:))
    billable = arrange.reserved_entry(company:, invoice_id: 962, state: "committed")
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare mark_billed])
    headers = { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(company_id: company, edit_days: 30, users: [], projects: [], missing_project_ids: [],
                          agents: [], owned_agent_ids: [])
    )
    counts = -> { [InvoiceOperation.count, Reservation.count, ServiceIdempotencyReceipt.count, Entry.sum(:version)] }
    before = counts.call

    post "/v1/companies/#{company}/reservations/prepare",
         params: JSON.generate("generation" => arrange.current_generation, "invoice_id" => 961,
                               "operation_id" => SecureRandom.uuid, "disposition" => "active", "entries" => [entry_id]),
         headers: headers
    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])

    post "/v1/companies/#{company}/invoices/962/mark-billed",
         params: JSON.generate("generation" => arrange.current_generation, "operation_id" => SecureRandom.uuid),
         headers: headers
    expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])

    expect(counts.call).to eq(before)
    expect(arrange.stored_entry(billable).fetch("bill_status")).to eq("unbilled")
  end
end

RSpec.describe "Timekeeping mark-billed of a hard-deleted invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "Timekeeping answers 404 `not_found` for an invoice id the reference does not list for the path company, unless the path company's own `invoice_operations` already hold that `invoice_id`"
  it "still bills an invoice the reference no longer lists when the path company's own invoice_operations hold it, and refuses it to another company" do
    arrange = timekeeping_arrange
    owner = arrange.company
    other = arrange.company
    arrange.invoice(company: owner, invoice_id: 971)
    owner_entry = arrange.entry(company: owner, user: arrange.user(company: owner, role: "employee"),
                                project: arrange.project(company: owner))
    services = [owner, other].index_with do |company|
      arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit mark_billed])
    end
    send_command = lambda do |company, path, body|
      post "/v1/companies/#{company}/#{path}",
           params: JSON.generate({ "generation" => arrange.current_generation }.merge(body)),
           headers: { "Authorization" => "Bearer #{services.fetch(company)}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    operation_id = SecureRandom.uuid
    expect(send_command.call(owner, "reservations/prepare", { "invoice_id" => 971, "operation_id" => operation_id,
                                                              "disposition" => "active", "entries" => [owner_entry] }).first)
      .to eq(200)
    expect(send_command.call(owner, "reservations/commit", { "invoice_id" => 971, "operation_id" => operation_id }).first)
      .to eq(200)

    # The monolith has hard-deleted invoice 971: its reference lists no invoice for either company.
    WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return do |request|
      company_id = Integer(request.uri.path[%r{/companies/(\d+)/}, 1], 10)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(company_id:, edit_days: 30, users: [], projects: [], missing_project_ids: [], agents: [],
                            owned_agent_ids: [], invoices: []) }
    end

    foreign = send_command.call(other, "invoices/971/mark-billed", { "operation_id" => SecureRandom.uuid })
    expect(foreign).to eq([404, { "reason" => "not_found" }])
    expect(ServiceIdempotencyReceipt.where(company_id: other).count).to eq(0)
    expect(arrange.stored_entry(owner_entry).fetch("bill_status")).to eq("unbilled")

    expect(send_command.call(owner, "invoices/971/mark-billed", { "operation_id" => SecureRandom.uuid }))
      .to eq([200, { "billed" => 1 }])
    expect(arrange.stored_entry(owner_entry).fetch("bill_status")).to eq("billed")
  end
end

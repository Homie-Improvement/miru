# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "Timekeeping mark-billed naming another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "mark-billed and detach-entries with zero targets for another company's ids store no receipt, pinned by request specs"
  # The answer must not tell the requesting service that the invoice id is in use by another company,
  # so it is compared with the answer for an invoice id no company uses.
  it "answers a mark-billed of another company's invoice as it answers an invoice that exists nowhere, billing nothing and storing no receipt" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    routes = %w[prepare commit abort mark_billed detach_entries]
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: routes)
    foreign_billable = arrange.reserved_entry(company: other_company, invoice_id: 501, state: "committed")
    expect(Entry.find(foreign_billable).bill_status).to eq("unbilled")
    receipts_before = ServiceIdempotencyReceipt.count
    versions_before = Entry.sum(:version)

    mark_billed = lambda do |invoice_id|
      post "/v1/companies/#{company}/invoices/#{invoice_id}/mark-billed",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    foreign = mark_billed.call(501)
    missing = mark_billed.call(990_001)

    expect(foreign).to eq(missing)
    expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(0)
    expect(ServiceIdempotencyReceipt.count).to eq(receipts_before)
    expect(Entry.find(foreign_billable).bill_status).to eq("unbilled")
    expect(Entry.sum(:version)).to eq(versions_before)
  end
end


RSpec.describe "Timekeeping mark-billed naming another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "mark-billed and detach-entries with zero targets for another company's ids store no receipt, pinned by request specs"
  it "stores no receipt and bills nothing for a mark-billed naming another company's invoice, in both directions" do
    arrange = timekeeping_arrange
    companies = [arrange.company, arrange.company]
    invoices = [501, 502]
    services = companies.map do |company|
      arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    end
    billable = companies.zip(invoices).map do |company, invoice_id|
      arrange.reserved_entry(company:, invoice_id:, state: "committed")
    end
    state = -> { [ServiceIdempotencyReceipt.count, Entry.sum(:version), Entry.where(id: billable).order(:id).pluck(:bill_status)] }

    baseline = state.call
    expect(baseline[2]).to eq(%w[unbilled unbilled])

    [[0, 1], [1, 0]].each do |requester, owner|
      post "/v1/companies/#{companies[requester]}/invoices/#{invoices[owner]}/mark-billed",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{services[requester]}", "Content-Type" => "application/json" }

      # Today the zero-target answer is 200 {"billed" => 0}; a refusal of another company's invoice id as
      # 404 not_found is also no match, and stores nothing either way.
      expect([[200, { "billed" => 0 }], [404, { "reason" => "not_found" }]])
        .to include([response.status, response.parsed_body])
      expect(state.call).to eq(baseline)
    end
  end
end


RSpec.describe "Timekeeping mark-billed retry after a zero-target answer" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A request that changes nothing stores no receipt, and a retry of it is evaluated again."
  # "Reason: the bulk route keeps the answer shape its callers know, and nothing was written, so a second evaluation is safe."
  it "evaluates a mark-billed retry again after a zero-target answer, then stores one receipt and never bills twice" do
    arrange = timekeeping_arrange
    company = arrange.company
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: %w[prepare commit abort mark_billed])
    operation_id = SecureRandom.uuid
    mark_billed = lambda do
      post "/v1/companies/#{company}/invoices/501/mark-billed",
           params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    expect(mark_billed.call).to eq([200, { "billed" => 0 }])
    expect(ServiceIdempotencyReceipt.count).to eq(0)

    billable = arrange.reserved_entry(company:, invoice_id: 501, state: "committed")
    expect(Entry.find(billable).bill_status).to eq("unbilled")

    # The same operation id now finds an entry to bill: it is evaluated, not replayed as {"billed" => 0}.
    expect(mark_billed.call).to eq([200, { "billed" => 1 }])
    expect(Entry.find(billable).bill_status).to eq("billed")
    expect(ServiceIdempotencyReceipt.count).to eq(1)
    version_after_billing = Entry.find(billable).version

    # From then on the stored answer is replayed and the entry is not written a second time.
    expect(mark_billed.call).to eq([200, { "billed" => 1 }])
    expect(ServiceIdempotencyReceipt.count).to eq(1)
    expect(Entry.find(billable).version).to eq(version_after_billing)
  end
end


RSpec.describe "Timekeeping mark-billed naming only another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "mark-billed and detach-entries with zero targets for another company's ids store no receipt, pinned by request specs"
  it "bills nothing and stores no service receipt when either company marks billed an invoice only the other company holds" do
    arrange = timekeeping_arrange
    first_company = arrange.company
    second_company = arrange.company
    invoices = { first_company => 611, second_company => 622 }
    seeded = invoices.to_h do |company, invoice_id|
      [company, { token: arrange.service_identity(company:, name: "invoice-boundary", operations: %w[mark_billed]),
                  entry: arrange.reserved_entry(company:, invoice_id:, state: "committed") }]
    end
    entry_ids = seeded.values.map { |values| values.fetch(:entry) }
    entries_before = Entry.where(id: entry_ids).order(:id).map(&:attributes)
    receipts_before = invoices.keys.index_with { |company| ServiceIdempotencyReceipt.where(company_id: company).count }
    expect(entries_before.map { |entry| entry.fetch("bill_status") }).to eq(%w[unbilled unbilled])

    [[first_company, second_company], [second_company, first_company]].each do |requester, owner|
      post "/v1/companies/#{requester}/invoices/#{invoices.fetch(owner)}/mark-billed",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{seeded.fetch(requester).fetch(:token)}", "Content-Type" => "application/json" }

      # The plan keeps today's 200 {"billed" => 0}; a separate change may refuse another company's
      # invoice id with 404 not_found instead. Either answer is a "no match".
      expect([[200, { "billed" => 0 }], [404, { "reason" => "not_found" }]])
        .to include([response.status, JSON.parse(response.body)])
    end

    # "Each spec shows that no receipt row is written for a request carrying only another company's ids."
    expect(invoices.keys.index_with { |company| ServiceIdempotencyReceipt.where(company_id: company).count })
      .to eq(receipts_before)
    expect(Entry.where(id: entry_ids).order(:id).map(&:attributes)).to eq(entries_before)
  end
end

RSpec.describe "Timekeeping mark-billed, another company's invoice id changes nothing" do
  include_context "timekeeping entry writes"

  # "mark-billed and detach-entries with zero targets for another company's ids store no receipt, pinned by request specs"
  # Another change may answer this request 404 not_found instead of 200 {"billed" => 0}; either answer
  # must leave no receipt behind.
  it "stores no service receipt when company B marks billed an invoice only company A has committed, and bills nothing" do
    company_a = timekeeping_arrange.company
    company_b = timekeeping_arrange.company
    committed_entry = timekeeping_arrange.reserved_entry(company: company_a, invoice_id: 502, state: "committed")
    service_b = timekeeping_arrange.service_identity(company: company_b, name: "invoice-boundary",
                                                     operations: %w[prepare commit abort mark_billed detach_entries])
    expect(timekeeping_arrange.stored_entry(committed_entry).fetch("bill_status")).to eq("unbilled")
    entry_before = Entry.find(committed_entry).attributes
    receipts_before = ServiceIdempotencyReceipt.where(company_id: [company_a, company_b]).count
    counts_before = [AuditEvent.count, OutboxSnapshot.count, Entry.sum(:version)]

    post "/v1/companies/#{company_b}/invoices/502/mark-billed",
         params: { "operation_id" => SecureRandom.uuid, "generation" => timekeeping_arrange.current_generation }.to_json,
         headers: { "Authorization" => "Bearer #{service_b}", "Content-Type" => "application/json" }

    expect([[200, { "billed" => 0 }], [404, { "reason" => "not_found" }]])
      .to include([response.status, JSON.parse(response.body)])
    # "a 2xx answer that changed nothing stores no receipt"
    expect(ServiceIdempotencyReceipt.where(company_id: [company_a, company_b]).count).to eq(receipts_before)
    expect(Entry.find(committed_entry).attributes).to eq(entry_before)
    expect([AuditEvent.count, OutboxSnapshot.count, Entry.sum(:version)]).to eq(counts_before)
  end
end

RSpec.describe "Timekeeping mark-billed, retrying an attempt that billed nothing" do
  include_context "timekeeping entry writes"

  # "A request that changes nothing stores no receipt, and a retry of it is evaluated again."
  it "evaluates a mark-billed retry again after a first attempt that billed nothing, and bills the entry committed since" do
    company_a = timekeeping_arrange.company
    company_b = timekeeping_arrange.company
    # Only company B holds invoice 501 when company A first marks it billed.
    foreign_entry = timekeeping_arrange.reserved_entry(company: company_b, invoice_id: 501, state: "committed")
    service_a = timekeeping_arrange.service_identity(company: company_a, name: "invoice-boundary",
                                                     operations: %w[prepare commit abort mark_billed detach_entries])
    operation_id = SecureRandom.uuid
    mark_billed = lambda do
      post "/v1/companies/#{company_a}/invoices/501/mark-billed",
           params: { "operation_id" => operation_id, "generation" => timekeeping_arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{service_a}", "Content-Type" => "application/json" }
      [response.status, JSON.parse(response.body)]
    end

    first = mark_billed.call
    expect([[200, { "billed" => 0 }], [404, { "reason" => "not_found" }]]).to include(first)
    expect(ServiceIdempotencyReceipt.where(company_id: [company_a, company_b]).count).to eq(0)
    expect(timekeeping_arrange.stored_entry(foreign_entry).fetch("bill_status")).to eq("unbilled")

    own_entry = timekeeping_arrange.reserved_entry(company: company_a, invoice_id: 501, state: "committed")
    retried = mark_billed.call

    # A replay of a stored first answer would repeat it and leave the new entry unbilled.
    expect(retried).to eq([200, { "billed" => 1 }])
    expect(timekeeping_arrange.stored_entry(own_entry).fetch("bill_status")).to eq("billed")
    expect(timekeeping_arrange.stored_entry(foreign_entry).fetch("bill_status")).to eq("unbilled")
    expect(ServiceIdempotencyReceipt.where(company_id: company_a, key: operation_id).count).to eq(1)
    expect(ServiceIdempotencyReceipt.where(company_id: company_b).count).to eq(0)
  end
end


RSpec.describe "Timekeeping mark-billed: another company's invoice" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "mark-billed and detach-entries with zero targets for another company's ids store no receipt, pinned by request specs"
  # The guard rule: such a request "returns `404` or no match and changes nothing in either database, in both directions".
  # Either answer satisfies that rule; which one depends on whether another company's invoice id is refused outright.
  it "stores no receipt for a twice-sent mark-billed of another company's invoice and leaves that company's own mark-billed under the same operation id to bill its entry" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    operations = %w[prepare commit abort mark_billed detach_entries]
    own_service = arrange.service_identity(company:, name: "invoice-boundary", operations:)
    foreign_service = arrange.service_identity(company: other_company, name: "invoice-boundary", operations:)
    foreign_billable = arrange.reserved_entry(company: other_company, invoice_id: 501, state: "committed")
    operation_id = SecureRandom.uuid
    mark_billed = lambda do |company_id, credential|
      post "/v1/companies/#{company_id}/invoices/501/mark-billed",
           params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{credential}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end
    expect(Entry.find(foreign_billable).bill_status).to eq("unbilled")
    counts = -> { [ServiceIdempotencyReceipt.count, AuditEvent.count, OutboxSnapshot.count, Entry.sum(:version)] }
    before = counts.call

    2.times do |attempt|
      answer = mark_billed.call(company, own_service)

      expect([[200, { "billed" => 0 }], [404, { "reason" => "not_found" }]]).to include(answer), "attempt #{attempt + 1}"
      expect(counts.call).to eq(before), "attempt #{attempt + 1}"
      expect(Entry.find(foreign_billable).bill_status).to eq("unbilled")
    end

    expect(mark_billed.call(other_company, foreign_service)).to eq([200, { "billed" => 1 }])
    expect(Entry.find(foreign_billable).bill_status).to eq("billed")
    expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(0)
    expect(ServiceIdempotencyReceipt.where(company_id: other_company).count).to eq(1)
  end
end


RSpec.describe "Timekeeping mark-billed: a retry after a first attempt that billed nothing" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # "A request that changes nothing stores no receipt, and a retry of it is evaluated again."
  # The first attempt finds no committed reservation, so it stores nothing; a stored {"billed" => 0}
  # would be replayed and leave the entry committed later unbilled for good.
  it "evaluates a mark-billed retry again after a first attempt that billed nothing, bills once, and then replays" do
    arrange = timekeeping_arrange
    company = arrange.company
    service = arrange.service_identity(company:, name: "invoice-boundary",
                                       operations: %w[prepare commit abort mark_billed detach_entries])
    operation_id = SecureRandom.uuid
    mark_billed = lambda do
      post "/v1/companies/#{company}/invoices/501/mark-billed",
           params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
      [response.status, response.parsed_body]
    end

    expect(mark_billed.call).to eq([200, { "billed" => 0 }])
    expect(ServiceIdempotencyReceipt.count).to eq(0)

    billable = arrange.reserved_entry(company:, invoice_id: 501, state: "committed")
    expect(Entry.find(billable).bill_status).to eq("unbilled")

    expect(mark_billed.call).to eq([200, { "billed" => 1 }])
    expect(Entry.find(billable).bill_status).to eq("billed")
    expect(ServiceIdempotencyReceipt.count).to eq(1)
    version = Entry.find(billable).version

    expect(mark_billed.call).to eq([200, { "billed" => 1 }])
    expect(ServiceIdempotencyReceipt.count).to eq(1)
    expect(Entry.find(billable).version).to eq(version)
  end
end

RSpec.describe "Timekeeping detach-entries naming another company's agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # A detach-entries receipt is also the marker that refuses a later entry write naming the agent being
  # deleted, and Timekeeping cannot tell another company's agent from an own agent with no entries, so a
  # detach that changed nothing still stores its receipt (contracts/timekeeping/idempotency.yml
  # unchanged_stored_operations).
  it "detaches nothing from the other company and still stores the requester's detach receipt" do
    arrange = timekeeping_arrange
    company = arrange.company
    other_company = arrange.company
    other_user = arrange.user(company: other_company, role: "employee")
    foreign_agent = arrange.agent(company: other_company, user: other_user)
    foreign_entry = arrange.entry(company: other_company, user: other_user, project: arrange.project(company: other_company),
                                  agent_id: foreign_agent)
    service = arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])
    expect(Entry.find(foreign_entry).agent_id).to eq(foreign_agent)
    entry_before = Entry.find(foreign_entry).attributes

    post "/v1/companies/#{company}/agents/#{foreign_agent}/detach-entries",
         params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
         headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }

    expect([response.status, response.parsed_body]).to eq([200, { "detached" => 0 }])
    expect(Entry.find(foreign_entry).attributes).to eq(entry_before)
    expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(1)
    expect(ServiceIdempotencyReceipt.where(company_id: other_company).count).to eq(0)
  end
end

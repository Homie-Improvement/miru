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


RSpec.describe "Timekeeping detach-entries naming another company's agent" do
  include_context "timekeeping entry writes"
  include_context "timekeeping entry writes without transactional fixtures"

  # A detach-entries receipt is the marker that refuses a later entry write naming the agent being
  # deleted, so only a detach of the requesting company's own agent stores it when it changed nothing
  # (contracts/timekeeping/idempotency.yml owned_target_stored_operations).
  it "detaches nothing from the other company and stores no detach receipt for either company" do
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
    expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(0)
    expect(ServiceIdempotencyReceipt.where(company_id: other_company).count).to eq(0)
  end

  context "when the agent belongs to another company" do
    # "The change still stores a receipt for the requesting company when a detach-entries call names another company's agent and detaches nothing."
    # The answer and the rows left behind must not tell the caller that the agent id is in use by another company,
    # so each call is compared with one naming an agent id no company uses, and a resend under the same
    # operation id must store nothing either.
    it "answers like an unused agent id and stores no receipt for either company, in both directions and on a resend" do
      arrange = timekeeping_arrange
      first = arrange.company
      second = arrange.company
      seeded = [first, second].index_with do |company|
        user = arrange.user(company:, role: "employee")
        agent = arrange.agent(company:, user:)
        entry = arrange.entry(company:, user:, project: arrange.project(company:), agent_id: agent)
        service = arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])
        { agent:, entry:, service: }
      end
      entries_before = seeded.values.to_h { |seed| [seed.fetch(:entry), Entry.find(seed.fetch(:entry)).attributes] }

      detach = lambda do |company, agent_id, operation_id|
        post "/v1/companies/#{company}/agents/#{agent_id}/detach-entries",
             params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
             headers: { "Authorization" => "Bearer #{seeded.fetch(company).fetch(:service)}",
                        "Content-Type" => "application/json" }
        [response.status, response.parsed_body]
      end

      [[first, second], [second, first]].each do |requester, owner|
        operation_id = SecureRandom.uuid
        foreign = detach.call(requester, seeded.fetch(owner).fetch(:agent), operation_id)
        resent = detach.call(requester, seeded.fetch(owner).fetch(:agent), operation_id)
        unused = detach.call(requester, 990_002, SecureRandom.uuid)

        expect(foreign).to eq([200, { "detached" => 0 }])
        expect(foreign).to eq(unused)
        expect(resent).to eq(unused)
        expect(ServiceIdempotencyReceipt.where(company_id: requester).count).to eq(0)
        expect(ServiceIdempotencyReceipt.where(company_id: owner).count).to eq(0)
        expect(ServiceIdempotencyReceipt.count).to eq(0)
        expect(entries_before.keys.index_with { |id| Entry.find(id).attributes }).to eq(entries_before)
      end
    end

    # Ownership is decided for the company the service token is bound to; a company_id the caller writes into the
    # body must not make another company's agent count as its own.
    it "ignores a company_id in the detach body, so naming the agent's own company there still stores nothing" do
      arrange = timekeeping_arrange
      company = arrange.company
      other_company = arrange.company
      other_user = arrange.user(company: other_company, role: "employee")
      foreign_agent = arrange.agent(company: other_company, user: other_user)
      foreign_entry = arrange.entry(company: other_company, user: other_user,
                                    project: arrange.project(company: other_company), agent_id: foreign_agent)
      service = arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])
      entry_before = Entry.find(foreign_entry).attributes

      post "/v1/companies/#{company}/agents/#{foreign_agent}/detach-entries",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation,
                     "company_id" => other_company }.to_json,
           headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }

      expect(response.status).not_to eq(503)
      expect(Entry.find(foreign_entry).attributes).to eq(entry_before)
      expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(0)
      expect(ServiceIdempotencyReceipt.where(company_id: other_company).count).to eq(0)
    end
  end

  context "when the agent is the company's own and has no entries" do
    # "That receipt is also the marker that blocks a later entry write naming an agent that is being deleted."
    it "stores one detach receipt under the requesting company only and replays it without storing a second" do
      arrange = timekeeping_arrange
      company = arrange.company
      other_company = arrange.company
      own_agent = arrange.agent(company:, user: arrange.user(company:, role: "employee"))
      service = arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])
      operation_id = SecureRandom.uuid

      detach = lambda do
        post "/v1/companies/#{company}/agents/#{own_agent}/detach-entries",
             params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
             headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
        [response.status, response.parsed_body]
      end

      first = detach.call
      receipts_after_first = ServiceIdempotencyReceipt.where(company_id: company).count
      replay = detach.call

      expect(first).to eq([200, { "detached" => 0 }])
      expect(receipts_after_first).to eq(1)
      expect(replay).to eq(first)
      expect(ServiceIdempotencyReceipt.where(company_id: company, operation: "detach_entries #{own_agent}").count).to eq(1)
      expect(ServiceIdempotencyReceipt.where(company_id: other_company).count).to eq(0)
      expect(ServiceIdempotencyReceipt.count).to eq(1)
    end
  end

  context "when the reference endpoint cannot answer" do
    # "That receipt is also the marker that blocks a later entry write naming an agent that is being deleted."
    # A detach must never answer 2xx without that marker when ownership cannot be read, and a detach whose
    # answer is already stored must still be answered from it, so a caller that lost the first answer can
    # confirm the detach while the monolith cannot be reached.
    it "replays a stored own-agent detach unchanged, but refuses a new detach with 503 and stores nothing" do
      arrange = timekeeping_arrange
      company = arrange.company
      own_user = arrange.user(company:, role: "employee")
      project = arrange.project(company:)
      own_agent = arrange.agent(company:, user: own_user)
      second_agent = arrange.agent(company:, user: own_user)
      detached_entry = arrange.entry(company:, user: own_user, project:, agent_id: own_agent)
      kept_entry = arrange.entry(company:, user: own_user, project:, agent_id: second_agent)
      service = arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])
      detach = lambda do |agent_id, operation_id|
        post "/v1/companies/#{company}/agents/#{agent_id}/detach-entries",
             params: { "operation_id" => operation_id, "generation" => arrange.current_generation }.to_json,
             headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
        [response.status, response.parsed_body]
      end
      stored_operation = SecureRandom.uuid

      expect(detach.call(own_agent, stored_operation)).to eq([200, { "detached" => 1 }])
      expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(1)
      detached_after_first = Entry.find(detached_entry).attributes
      kept_before = Entry.find(kept_entry).attributes

      WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500)

      expect(detach.call(own_agent, stored_operation)).to eq([200, { "detached" => 1 }])
      expect(Entry.find(detached_entry).attributes).to eq(detached_after_first)
      expect(Entry.find(detached_entry).agent_id).to be_nil
      expect(detach.call(second_agent, SecureRandom.uuid)).to eq([503, { "reason" => "reference_unavailable" }])
      expect(Entry.find(kept_entry).attributes).to eq(kept_before)
      expect(ServiceIdempotencyReceipt.count).to eq(1)
    end

    # A reference answer from a monolith that does not yet send owned_agent_ids says nothing about ownership.
    # Reading it as "not owned" would answer 2xx with no marker for the company's own agent, so the
    # detach must fail closed instead.
    it "refuses a detach with 503 and stores no marker when the reference answer carries no owned_agent_ids" do
      arrange = timekeeping_arrange
      company = arrange.company
      own_user = arrange.user(company:, role: "employee")
      own_agent = arrange.agent(company:, user: own_user)
      service = arrange.service_identity(company:, name: "agent-destroy", operations: %w[detach_entries])
      facts_without_ownership = {
        company_id: company, edit_days: 30, users: [{ id: own_user, role: "employee" }], projects: [],
        missing_project_ids: [], agents: [{ id: own_agent, user_id: own_user }]
      }
      WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(facts_without_ownership)
      )

      post "/v1/companies/#{company}/agents/#{own_agent}/detach-entries",
           params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
           headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }

      expect([response.status, response.parsed_body]).to eq([503, { "reason" => "reference_unavailable" }])
      expect(ServiceIdempotencyReceipt.where(company_id: company).count).to eq(0)
    end
  end

  context "when another company detached the same agent id first" do
    # "That receipt is also the marker that blocks a later entry write naming an agent that is being deleted."
    # Ordering: another company's service detaches this agent id first, then the owning company deletes
    # its agent, which has no entries. The foreign detach must leave nothing, and the owning company's
    # detach must still leave the marker that refuses a create whose fence was read before the detach.
    it "keeps the own-agent delete marker, which refuses a create fenced before the detach" do
      arrange = timekeeping_arrange
      owner_company = arrange.company
      other_company = arrange.company
      owner = arrange.user(company: owner_company, role: "owner")
      project = arrange.project(company: owner_company)
      own_agent = arrange.agent(company: owner_company, user: owner)
      owner_service = arrange.service_identity(company: owner_company, name: "agent-destroy", operations: %w[detach_entries])
      other_service = arrange.service_identity(company: other_company, name: "agent-destroy", operations: %w[detach_entries])
      detach = lambda do |company, service|
        post "/v1/companies/#{company}/agents/#{own_agent}/detach-entries",
             params: { "operation_id" => SecureRandom.uuid, "generation" => arrange.current_generation }.to_json,
             headers: { "Authorization" => "Bearer #{service}", "Content-Type" => "application/json" }
        [response.status, response.parsed_body]
      end
      fenced_create = build_entry_command(
        :create, token: arrange.token_for(owner),
                 body: { "project_id" => project, "work_date" => "2026-03-02", "duration" => 60.0, "note" => "Late",
                         "source" => "manual", "source_metadata" => {}, "agent_id" => own_agent }
      )

      expect(detach.call(other_company, other_service)).to eq([200, { "detached" => 0 }])
      expect(ServiceIdempotencyReceipt.count).to eq(0)

      expect(detach.call(owner_company, owner_service)).to eq([200, { "detached" => 0 }])
      expect(ServiceIdempotencyReceipt.where(company_id: owner_company).count).to eq(1)
      expect(ServiceIdempotencyReceipt.where(company_id: other_company).count).to eq(0)

      outcome = Timekeeping::EntryWriter.new.call(fenced_create)

      expect([outcome.status, JSON.parse(outcome.body)]).to eq([404, { "reason" => "not_found" }])
      expect(Entry.where(company_id: owner_company).count).to eq(0)
    end
  end
end

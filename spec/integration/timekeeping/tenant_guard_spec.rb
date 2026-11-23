# frozen_string_literal: true

require "rails_helper"
require "json"
require "securerandom"

# The tenant guard of docs/architecture/timekeeping-soa.md section 12.2, run
# against the live demo runtime (spec/support/timekeeping/integrated_runtime.rb)
# on both seeded companies: "On both seeded tenants, for each Timekeeping
# endpoint and command and for the projection endpoint: a request for company A
# carrying an entry id, invoice id, operation id or idempotency key from company
# B returns 404 or no match, and changes nothing."
#
# The spec only interprets TenantGuardCases::ALL. For every case it shows the
# owner's identifier is stored under the owner's company, takes all four
# per-company digests (requester and owner, monolith and Timekeeping), sends the
# requester's request, and requires the case's exact expected answer with every
# digest unchanged. The owner's own request is the positive control: before the
# requester for reads, replays and snapshot delivery, and after the digest
# comparison for routes that change data.
#
# Each direction is one example, so the runtime boots twice rather than once per
# case; every case reads its ids again, because earlier cases' controls discard,
# reserve and bill rows. Operation ids and idempotency keys do not exist in the
# seed, so each comes from the owner's own setup request in the same case.
RSpec.describe "Timekeeping tenant guard", type: :request, committed_data: true do
  # The runtime's readiness checks and every request here go to 127.0.0.1. An
  # around hook wraps the suite's before hooks, so this is in place before the
  # runtime hook boots the launcher.
  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true)
    example.run
  ensure
    # Back to the suite default (spec/rails_helper.rb), so no later spec may reach localhost.
    WebMock.disable_net_connect!
  end

  [%i[fork_and_leaf copper_kettle], %i[copper_kettle fork_and_leaf]].each do |requester_name, owner_name|
    it "answers #{requester_name} carrying #{owner_name}'s identifiers with 404 or no match and changes nothing",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "timekeeping" do
      tenant_guard_run(requester: public_send(requester_name), owner: public_send(owner_name))
    end
  end

  # The relay sends every 10 seconds, so a digest is taken only once neither
  # store holds an unsent snapshot for either company.
  def tenant_guard_outbox_within_seconds = 30

  # The routes that change data, whose probes must run before the owner's control.
  def tenant_guard_mutating_routes
    %i[update destroy bulk_move bulk_delete prepare commit abort mark_billed detach_entries].freeze
  end

  # The service token operation each reservations route requires.
  def tenant_guard_route_operations
    {
      prepare: Timekeeping::ServiceToken::RESERVATIONS_PREPARE,
      commit: Timekeeping::ServiceToken::RESERVATIONS_COMMIT,
      abort: Timekeeping::ServiceToken::RESERVATIONS_ABORT,
      mark_billed: Timekeeping::ServiceToken::INVOICES_MARK_BILLED,
      detach_entries: Timekeeping::ServiceToken::DETACH_ENTRIES
    }.freeze
  end

  # Where each owner identifier kind is stored, per contract and route:
  # [database, SQL with $1 the owner's company and $2 the identifier, ids key].
  # Each row holds the stored row's id and, for a receipt, the answer body it
  # stores, which a replay under another company must never return.
  def tenant_guard_identifier_lookup(kase, kind)
    case [kase.contract, kase.route, kind]
    in [_, _, :entry_id]
      [:timekeeping, "SELECT id, NULL AS body FROM entries WHERE company_id = $1 AND id = $2", :entry_id]
    in [_, _, :invoice_id]
      [:monolith, "SELECT id, NULL AS body FROM invoices WHERE company_id = $1 AND id = $2", :invoice_id]
    in [:reservations, :prepare | :commit | :abort, :operation_id | :idempotency_key]
      [:timekeeping, "SELECT id, NULL AS body FROM invoice_operations WHERE company_id = $1 AND operation_id = $2::uuid",
       :operation_id]
    in [:reservations, :mark_billed | :detach_entries, :operation_id | :idempotency_key]
      [:timekeeping, "SELECT id, body FROM service_idempotency_receipts WHERE company_id = $1 AND key = $2", :operation_id]
    in [:entry_api, _, :idempotency_key]
      [:timekeeping, "SELECT id, body FROM idempotency_receipts WHERE company_id = $1 AND key = $2", :idempotency_key]
    in [:entry_snapshots, _, :idempotency_key]
      [:monolith, "SELECT id, response_body AS body FROM entry_snapshot_receipts WHERE $1 = ANY(company_ids) AND key = $2",
       :idempotency_key]
    end
  end

  # What an owner's entry write control must leave on its entry, so a route
  # that answers 2xx while changing nothing cannot pass as the positive
  # control: the bulk result naming the entry (nil on a single-entry route)
  # and whether the entry ends discarded. Every write also advances the
  # entry's version by one (Timekeeping::EntryWriter#apply_change).
  def tenant_guard_entry_write_effects
    { update: [nil, false], destroy: [nil, true], bulk_move: ["moved", false], bulk_delete: ["deleted", true] }.freeze
  end

  # The owner's own requests a case needs before its identifier exists:
  # [route, operation], where operation :case uses the case's own operation id
  # and :setup a separate one. Commit and abort act on an operation the owner
  # prepared; the key probes of destroy and bulk_delete need the owner's
  # stored receipt; the mark_billed replay needs committed entries to bill,
  # because a mark-billed that bills nothing stores no receipt.
  def tenant_guard_owner_setup(kase)
    case [kase.contract, kase.route, kase.mode, kase.covers]
    in [:reservations, :commit | :abort, :probe, _] | [:reservations, :prepare, :probe, [:operation_id]]
      [%i[prepare case]]
    in [:reservations, :mark_billed, :replay, _]
      [%i[prepare setup], %i[commit setup]]
    in [:entry_api, :destroy | :bulk_delete, :probe, [:idempotency_key]]
      [[kase.route, :case]]
    else
      []
    end
  end

  def tenant_guard_run(requester:, owner:)
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL)).to eq(routes: [], pairs: [])
    mutating_probes = TenantGuardCases::ALL.select do |kase|
      kase.mode == :probe && kase.covers != [:none] && tenant_guard_mutating_routes.include?(kase.route)
    end
    expect(mutating_probes.map(&:first).uniq).to eq([:requester])

    checkpoint = TenantGuardSeedLoad.load!(runtime: @integrated_runtime)
    last_seeded_entry_id = checkpoint.rows.fetch("entries").map { |row| row.fetch("id") }.max
    parties = { requester: tenant_guard_party(requester, last_seeded_entry_id:),
                owner: tenant_guard_party(owner, last_seeded_entry_id:) }
    TenantGuardCases::ALL.each { |kase| tenant_guard_case(kase, **parties) }
  end

  # The company's owner, whose current workspace is the company, its first
  # billable project, and an agent of its own: the seed holds no agents, and
  # detach-entries names one. last_seeded_entry_id keeps the entries cases
  # create out of the foreign identifiers, which must be seeded.
  def tenant_guard_party(company, last_seeded_entry_id:)
    user = User.with_role(:owner, company).find_by!(current_workspace_id: company.id)
    project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
    { company:, user:, project:, agent: create(:agent, company:, default_project: project), last_seeded_entry_id: }
  end

  # One company's ids in the case table's shape, read again for every case.
  # Entries are the company's kept seeded Timekeeping entries, unlocked ones
  # first, so an entry an earlier control discarded is never reused.
  def tenant_guard_ids(party)
    company_id = party.fetch(:company).id
    entries = tenant_guard_timekeeping_rows(<<~SQL.squish, [company_id, party.fetch(:last_seeded_entry_id)])
      SELECT id, version FROM entries
      WHERE company_id = $1 AND discarded_at IS NULL AND id <= $2
      ORDER BY locked IS TRUE, id LIMIT 2
    SQL
    expect(entries).not_to be_empty, "company #{company_id} has no kept Timekeeping entry left"
    {
      company_id:, user_id: party.fetch(:user).id, project_id: party.fetch(:project).id,
      agent_id: party.fetch(:agent).id, entry_ids: entries.map { |row| Integer(row.fetch("id")) },
      entry_versions: entries.to_h { |row| [Integer(row.fetch("id")), Integer(row.fetch("version"))] },
      invoice_id: Invoice.where(company_id:).order(:id).pick(:id), operation_id: SecureRandom.uuid,
      idempotency_key: SecureRandom.uuid, generation: TenantGuardSeedLoad.admission_generation
    }
  end

  def tenant_guard_case(kase, requester:, owner:)
    label = "#{kase.contract}.#{kase.route} #{kase.mode} #{kase.covers.join('+')}"
    ids = { requester: tenant_guard_ids(requester), owner: tenant_guard_ids(owner) }
    return tenant_guard_reference_case(kase, requester:, owner:, ids:, label:) if kase.contract == :reference

    owner_own = tenant_guard_own_ids(kase, ids.fetch(:owner), owner, label)
    tenant_guard_run_owner_setup(kase, owner_own, owner, label)
    recorded = tenant_guard_own_request(kase, owner_own, owner, "#{label} owner control") if tenant_guard_owner_first?(kase)
    stored = tenant_guard_expect_owner_identifiers(kase, ids.fetch(:owner), label)
    requester_own = tenant_guard_requester_precondition(kase, ids.fetch(:requester), requester, label)

    request = tenant_guard_requester_request(kase, recorded, ids, requester)
    tenant_guard_compare(kase, request, ids, requester:, label:, recorded: recorded&.merge(stored:))

    tenant_guard_abort(requester_own, requester, "#{label} requester") if requester_own
    tenant_guard_owner_control_after(kase, owner_own, owner, label) if tenant_guard_owner_after?(kase)
    tenant_guard_abort(owner_own, owner, "#{label} owner") if kase.contract == :reservations && kase.route == :prepare
  end

  # The owner's control after a requester-first probe. On an entry write it
  # must also have changed the owner's entry as the route says.
  def tenant_guard_owner_control_after(kase, owner_own, owner, label)
    control = tenant_guard_own_request(kase, owner_own, owner, "#{label} owner control")
    return unless tenant_guard_entry_write?(kase)

    bulk_result, discarded = tenant_guard_entry_write_effects.fetch(kase.route)
    entry_id = owner_own.fetch(:entry_ids).first
    if bulk_result
      expect(tenant_guard_json(control.fetch(:reply))["results"])
        .to eq([{ "entry_id" => entry_id, "result" => bulk_result }]), "#{label}: the owner control's bulk result"
    end
    stored = tenant_guard_timekeeping_rows(
      "SELECT version, discarded_at IS NOT NULL AS discarded FROM entries WHERE company_id = $1 AND id = $2",
      [owner_own.fetch(:company_id), entry_id]
    )
    expect(stored).to eq([{ "version" => (owner_own.fetch(:entry_versions).fetch(entry_id) + 1).to_s,
                            "discarded" => discarded ? "t" : "f" }]),
                      "#{label}: the owner control left entry #{entry_id} as #{stored.inspect}"
  end

  def tenant_guard_entry_write?(kase)
    kase.contract == :entry_api && tenant_guard_entry_write_effects.key?(kase.route)
  end

  # The ids a company's own write requests use. The seed's unbilled entries are
  # all reserved and its billed ones refuse changes (Copper Kettle's seed holds
  # only billed entries), so each write or reservation case acts on a new entry
  # the company creates for itself. The foreign identifiers a probe sends stay
  # the seeded ones.
  def tenant_guard_own_ids(kase, party_ids, party, label)
    return party_ids unless kase.contract == :reservations || tenant_guard_entry_write?(kase)

    create = TenantGuardCases::ALL.find { |candidate| candidate.contract == :entry_api && candidate.route == :create }
    created = tenant_guard_own_request(create, party_ids.merge(idempotency_key: SecureRandom.uuid), party,
                                       "#{label} own entry")
    entry = tenant_guard_json(created.fetch(:reply))
    party_ids.merge(entry_ids: [entry.fetch("id")], entry_versions: { entry.fetch("id") => entry.fetch("version") })
  end

  # Reads, replays and snapshot delivery show the owner's row or receipt first.
  def tenant_guard_owner_first?(kase)
    kase.mode == :replay || kase.first == :owner
  end

  def tenant_guard_owner_after?(kase)
    kase.mode == :probe && kase.first == :requester && kase.covers != [:none]
  end

  def tenant_guard_entry_list?(kase)
    kase.contract == :entry_api && kase.route == :index
  end

  def tenant_guard_run_owner_setup(kase, owner_ids, owner, label)
    setup_ids = owner_ids.merge(operation_id: SecureRandom.uuid)
    tenant_guard_owner_setup(kase).each do |route, operation|
      tenant_guard_own_route_request(kase.contract, route, operation == :case ? owner_ids : setup_ids, owner,
                                     "#{label} owner setup #{route}")
    end
    tenant_guard_agent_entry(owner_ids, owner, label) if kase.route == :detach_entries
  end

  # Gives the owner's agent an entry, so the owner's detach detaches one and
  # its stored answer differs from the requester's no-match answer: a replay
  # leaking that receipt across companies would then fail the case. The
  # entry belongs to the agent's own user, as entry_api.yml rules.agent_owner
  # requires.
  def tenant_guard_agent_entry(owner_ids, owner, label)
    agent = owner.fetch(:agent)
    create = TenantGuardCases::ALL.find { |candidate| candidate.contract == :entry_api && candidate.route == :create }
    request = TenantGuardCases.valid_request(create, ids: owner_ids.merge(idempotency_key: SecureRandom.uuid))
    request = request.merge(body: request.fetch(:body).merge("user_id" => agent.user_id, "agent_id" => agent.id))
    reply = LiveHandoff.send_request(tenant_guard_base_url(create), tenant_guard_authorized(request, create, owner))
    expect(reply.status).to be_between(200, 299), "#{label}: the owner's agent entry answered #{reply.status}"
  end

  # A company's own valid request for the case, which must succeed. Returns
  # the request with its Authorization header and the reply, for a replay.
  def tenant_guard_own_request(kase, party_ids, party, label)
    request = tenant_guard_authorized(TenantGuardCases.valid_request(kase, ids: party_ids), kase, party)
    reply = LiveHandoff.send_request(tenant_guard_base_url(kase), request)
    expect(reply.status).to be_between(200, 299), "#{label}: the company's own request answered #{reply.status}"
    { request:, reply: }
  end

  # A company's own request on a route of the contract, which must succeed.
  # Replay-only headers are dropped, so a setup destroy really discards and
  # stores the receipt the key probe then names.
  def tenant_guard_own_route_request(contract, route, party_ids, party, label)
    kase = TenantGuardCases::ALL.find { |candidate| candidate.contract == contract && candidate.route == route }
                                .with(headers: {})
    tenant_guard_own_request(kase, party_ids, party, label)
  end

  def tenant_guard_abort(party_ids, party, label)
    tenant_guard_own_route_request(:reservations, :abort, party_ids, party, "#{label} abort")
  end

  # Returns the stored rows found for each identifier kind the case covers.
  def tenant_guard_expect_owner_identifiers(kase, owner_ids, label)
    (kase.covers - [:none]).to_h do |kind|
      database, sql, key = tenant_guard_identifier_lookup(kase, kind)
      value = key == :entry_id ? owner_ids.fetch(:entry_ids).first : owner_ids.fetch(key)
      params = [owner_ids.fetch(:company_id), value.to_s]
      rows = database == :timekeeping ? tenant_guard_timekeeping_rows(sql, params) : tenant_guard_monolith_rows(sql, params)
      expect(rows).not_to be_empty, "#{label}: the owner's #{kind} #{value} is not stored under the owner's company"
      [kind, rows]
    end
  end

  # The prepare operation probe needs an open operation on the requester's own
  # invoice, so an operation id it has never used answers unresolved_operation.
  # Returns the ids of that operation, which the case aborts afterwards.
  def tenant_guard_requester_precondition(kase, requester_ids, requester, label)
    return unless kase.precondition == TenantGuardCases::REQUESTER_OPEN_OPERATION

    open_ids = tenant_guard_own_ids(kase, requester_ids, requester, "#{label} requester")
    tenant_guard_own_route_request(:reservations, :prepare, open_ids, requester, "#{label} requester open operation")
    open_ids
  end

  def tenant_guard_requester_request(kase, recorded, ids, requester)
    if kase.mode == :replay
      return TenantGuardCases.replay_request(recorded.fetch(:request), company_id: ids.fetch(:requester).fetch(:company_id),
                                                                       authorization: tenant_guard_bearer(kase, requester))
    end

    probe = TenantGuardCases.probe_request(kase, requester: ids.fetch(:requester), owner: ids.fetch(:owner))
    tenant_guard_authorized(probe, kase, requester)
  end

  def tenant_guard_compare(kase, request, ids, requester:, label:, recorded:)
    observed_before = tenant_guard_observed(kase, ids)
    reply = tenant_guard_unchanged(kase, request, ids, label)
    expect(tenant_guard_observed(kase, ids)).to eq(observed_before), "#{label}: the requester's row or a refusal changed"
    tenant_guard_expect_answer(kase, reply, ids.fetch(:owner), label)
    unused_reply = tenant_guard_unused_operation_reply(kase, ids, requester, label)
    tenant_guard_expect_route_answer(kase, reply, ids, label:, recorded:, unused_reply:)
  end

  # Sends one request between two sets of all four digests and requires
  # them equal. Returns the reply.
  def tenant_guard_unchanged(kase, request, ids, label)
    company_ids = [ids.fetch(:requester).fetch(:company_id), ids.fetch(:owner).fetch(:company_id)]
    before = tenant_guard_states(company_ids, "#{label} baseline")
    reply = LiveHandoff.send_request(tenant_guard_base_url(kase), request)
    expect(tenant_guard_states(company_ids, "#{label} after")).to eq(before), "#{label}: a digest changed"
    reply
  end

  # Facts the digests leave out but a case still must not change: the
  # requester's projection row version (snapshot delivery) and the owner's
  # stale-generation refusal rows, a table the digest does not measure.
  def tenant_guard_observed(kase, ids)
    return {} unless kase.contract == :entry_snapshots

    requester_entry = ids.fetch(:requester).fetch(:entry_ids).first
    {
      requester_version: TimesheetEntry.unscoped.where(id: requester_entry).pick(:version),
      owner_refusals: tenant_guard_monolith_rows(
        "SELECT count(*) AS refusals FROM timekeeping_stale_generation_refusals WHERE company_id = $1",
        [ids.fetch(:owner).fetch(:company_id)]
      ).first.fetch("refusals")
    }
  end

  # For the prepare operation probe, the same request with an operation id no
  # company has used, so the answer to the owner's id is shown to reveal
  # nothing about whether the owner used it. It must change nothing either.
  def tenant_guard_unused_operation_reply(kase, ids, requester, label)
    return unless kase.precondition == TenantGuardCases::REQUESTER_OPEN_OPERATION && kase.covers == [:operation_id]

    unused_owner = ids.fetch(:owner).merge(operation_id: SecureRandom.uuid)
    probe = TenantGuardCases.probe_request(kase, requester: ids.fetch(:requester), owner: unused_owner)
    tenant_guard_unchanged(kase, tenant_guard_authorized(probe, kase, requester), ids, "#{label} unused operation id")
  end

  def tenant_guard_expect_answer(kase, reply, owner_ids, label)
    expected, actual = tenant_guard_answers(kase, reply, owner_ids)
    expect(actual).to eq(expected), "#{label}: answered #{reply.status} #{tenant_guard_json(reply).inspect}"
  end

  # The case's expected answer and the reply's, each as status, reason and
  # the expected answer's other fields (bulk results, conflicts, a count).
  def tenant_guard_answers(kase, reply, owner_ids)
    expected = TenantGuardCases.expected_answer(kase, owner: owner_ids)
    extra = JSON.parse(JSON.generate(expected.except(:status, :reason)))
    body = tenant_guard_json(reply)
    [[expected.fetch(:status), expected.fetch(:reason), extra], [reply.status, body["reason"], body.slice(*extra.keys)]]
  end

  def tenant_guard_expect_route_answer(kase, reply, ids, label:, recorded:, unused_reply:)
    body = tenant_guard_json(reply)
    tenant_guard_expect_no_owner_receipt(kase, reply, recorded, ids, label) if kase.mode == :replay
    tenant_guard_expect_entry_list(body, ids, label) if tenant_guard_entry_list?(kase)
    return unless unused_reply

    requester_operation = ids.fetch(:requester).fetch(:operation_id)
    expect(body["operation_id"]).to eq(requester_operation), "#{label}: the refusal names #{body['operation_id']}"
    expect([unused_reply.status, tenant_guard_json(unused_reply)]).to eq([reply.status, body]),
                                                                       "#{label}: an unused operation id answered differently"
  end

  # The requester's answer may carry no id of the owner's answer or of the
  # stored row behind it (receipt or operation), and neither the owner's
  # answer nor the stored receipt body, at any depth. The owner's answer must
  # differ from the expected one, or a replay that returned the owner's
  # receipt would read as the expected answer.
  def tenant_guard_expect_no_owner_receipt(kase, reply, recorded, ids, label)
    owner_body = tenant_guard_json(recorded.fetch(:reply))
    expected, owner_answer = tenant_guard_answers(kase, recorded.fetch(:reply), ids.fetch(:owner))
    expect(owner_answer).not_to eq(expected), "#{label}: the owner's stored answer equals the expected answer"

    stored = recorded.fetch(:stored).fetch(:idempotency_key)
    owner_ids = tenant_guard_identifying_values(owner_body) + stored.map { |row| row.fetch("id").to_s }
    owner_bodies = [owner_body, *stored.filter_map { |row| tenant_guard_stored_body(row.fetch("body")) }].reject(&:blank?)
    answer = tenant_guard_json(reply)
    leaked = (owner_ids & tenant_guard_identifying_values(answer)) + (owner_bodies & tenant_guard_nested_values(answer))
    expect(leaked).to eq([]), "#{label}: the requester's answer carries the owner's stored answer #{leaked.inspect}"
  end

  # Values under an id key ("id" or "..._id"), at any depth, as strings.
  def tenant_guard_identifying_values(value)
    case value
    when Hash
      value.flat_map do |key, nested|
        key == "id" || key.end_with?("_id") ? [nested.to_s] : tenant_guard_identifying_values(nested)
      end
    when Array then value.flat_map { |nested| tenant_guard_identifying_values(nested) }
    else []
    end
  end

  # The value and every hash or array nested in it.
  def tenant_guard_nested_values(value)
    case value
    when Hash then [value, *value.values.flat_map { |nested| tenant_guard_nested_values(nested) }]
    when Array then [value, *value.flat_map { |nested| tenant_guard_nested_values(nested) }]
    else []
    end
  end

  # A stored receipt body is JSON text (Timekeeping::WriteOutcome, and jsonb in
  # entry_snapshot_receipts); an operation row stores no body.
  def tenant_guard_stored_body(text)
    text && JSON.parse(text)
  end

  # The entry list answers 200 for the requester's own company; it must hold
  # a requester entry and none of the owner's.
  def tenant_guard_expect_entry_list(body, ids, label)
    listed = body.fetch("entries").map { |entry| entry.fetch("id") }
    owner_entries = tenant_guard_timekeeping_rows("SELECT id FROM entries WHERE company_id = $1",
                                                  [ids.fetch(:owner).fetch(:company_id)]).map { |row| Integer(row.fetch("id")) }
    expect(listed & ids.fetch(:requester).fetch(:entry_ids)).not_to be_empty, "#{label}: no requester entry listed"
    expect(listed & owner_entries).to eq([]), "#{label}: the owner's entries were listed"
  end

  # The reference route takes project, agent and invoice ids in its query,
  # which the case table does not build. The requester's own ids must come
  # back; the owner's must not, and the owner's project is reported missing.
  def tenant_guard_reference_case(kase, requester:, owner:, ids:, label:)
    request = tenant_guard_authorized(TenantGuardCases.valid_request(kase, ids: ids.fetch(:requester)), kase, requester)
    with_query = lambda do |party_ids|
      query = { project_ids: party_ids.fetch(:project_id), agent_ids: party_ids.fetch(:agent_id),
                invoice_ids: party_ids.fetch(:invoice_id) }.to_query
      request.merge(path: "#{request.fetch(:path)}?#{query}")
    end

    control = tenant_guard_json(LiveHandoff.send_request(@integrated_runtime.monolith_url, with_query.call(ids.fetch(:requester))))
    expect(tenant_guard_reference_ids(control)).to eq(tenant_guard_reference_expected(ids.fetch(:requester))),
                                                   "#{label}: the requester's own ids were not returned"
    tenant_guard_expect_owner_identifiers(kase.with(covers: %i[invoice_id]), ids.fetch(:owner), label)
    expect(owner.fetch(:agent).company_id).to eq(ids.fetch(:owner).fetch(:company_id))

    company_ids = [ids.fetch(:requester).fetch(:company_id), ids.fetch(:owner).fetch(:company_id)]
    before = tenant_guard_states(company_ids, "#{label} baseline")
    reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, with_query.call(ids.fetch(:owner)))
    after = tenant_guard_states(company_ids, "#{label} after")

    expect(after).to eq(before), "#{label}: a digest changed"
    tenant_guard_expect_answer(kase, reply, ids.fetch(:owner), label)
    body = tenant_guard_json(reply)
    expect(tenant_guard_reference_ids(body)).to eq(projects: [], agents: [], invoices: []),
                                                "#{label}: the owner's ids were returned"
    expect(body.fetch("missing_project_ids")).to eq([ids.fetch(:owner).fetch(:project_id)])
    expect(body.fetch("agents").map { |agent| agent.fetch("id") }).not_to include(ids.fetch(:owner).fetch(:agent_id))
  end

  def tenant_guard_reference_ids(body)
    {
      projects: body.fetch("projects").map { |project| project.fetch("id") },
      agents: body.fetch("owned_agent_ids"),
      invoices: body.fetch("invoices").map { |invoice| invoice.fetch("id") }
    }
  end

  def tenant_guard_reference_expected(party_ids)
    { projects: [party_ids.fetch(:project_id)], agents: [party_ids.fetch(:agent_id)],
      invoices: [party_ids.fetch(:invoice_id)] }
  end

  def tenant_guard_states(company_ids, label)
    tenant_guard_outbox_sent!(company_ids, label)
    timekeeping_url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    company_ids.index_with { |company_id| TenantStateDigest.take(company_id:, timekeeping_url:) }
  end

  # A timeout raises, so no digest is ever taken while a snapshot is on its way.
  def tenant_guard_outbox_sent!(company_ids, label)
    companies = PG::TextEncoder::Array.new.encode(company_ids)
    TimekeepingGuardDrain.poll_until(case_name: label, awaiting: "no unsent outbox snapshot for either company",
                                     within: tenant_guard_outbox_within_seconds) do
      unsent_sql = "SELECT 1 FROM %s WHERE sent_at IS NULL AND company_id = ANY($1::bigint[]) LIMIT 1"
      tenant_guard_monolith_rows(format(unsent_sql, "entry_outbox_items"), [companies]).empty? &&
        tenant_guard_timekeeping_rows(format(unsent_sql, "outbox_snapshots"), [companies]).empty?
    end
  end

  def tenant_guard_bearer(kase, party)
    token =
      case kase.credential
      when :user_token
        Timekeeping::UserToken.mint(user: party.fetch(:user), company: party.fetch(:company),
                                    project_ids: [party.fetch(:project).id], private_key: tenant_guard_private_key)
      when :service_token
        Timekeeping::ServiceToken.mint(company_id: party.fetch(:company).id, operations: tenant_guard_operations(kase),
                                       private_key: tenant_guard_private_key)
      when :timekeeping_service
        # The projection and reference routes accept only the runtime's own
        # service token; a minted token is refused before any tenant check.
        @integrated_runtime.credentials.service_token
      end
    "Bearer #{token}"
  end

  # A handoff route takes no operation; the requester's token carries every
  # operation it could hold, so a 401 cannot come from a missing operation.
  def tenant_guard_operations(kase)
    return tenant_guard_route_operations.values if kase.contract == :handoff

    [tenant_guard_route_operations.fetch(kase.route)]
  end

  def tenant_guard_private_key
    OpenSSL::PKey::RSA.new(@integrated_runtime.credentials.private_key_pem)
  end

  def tenant_guard_authorized(request, kase, party)
    request.merge(headers: request.fetch(:headers).merge("Authorization" => tenant_guard_bearer(kase, party)))
  end

  # The projection and reference routes are the monolith's; every other route is Timekeeping's.
  def tenant_guard_base_url(kase)
    %i[entry_snapshots reference].include?(kase.contract) ? @integrated_runtime.monolith_url : @integrated_runtime.timekeeping_url
  end

  def tenant_guard_json(reply)
    parsed = JSON.parse(reply.body)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def tenant_guard_timekeeping_rows(sql, params)
    TimekeepingLiveHandoff.with_timekeeping_database { |connection| connection.exec_params(sql, params).to_a }
  end

  def tenant_guard_monolith_rows(sql, params)
    ActiveRecord::Base.connection.raw_connection.exec_params(sql, params).to_a
  end
end

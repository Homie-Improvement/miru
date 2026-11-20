# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping tenant guard surfaces and cases" do
  let(:contracts) { TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) } }
  let(:requester_ids) do
    { company_id: 101, user_id: 201, project_id: 301, agent_id: 401, entry_ids: [501, 502],
      entry_versions: { 501 => 3, 502 => 4 }, invoice_id: 601, operation_id: "op-requester-0001",
      idempotency_key: "key-requester-0001", generation: 2 }
  end
  let(:owner_ids) do
    { company_id: 1101, user_id: 1201, project_id: 1301, agent_id: 1401, entry_ids: [1501, 1502],
      entry_versions: { 1501 => 7, 1502 => 8 }, invoice_id: 1601, operation_id: "op-owner-0001",
      idempotency_key: "key-owner-0001", generation: 2 }
  end

  # A deep copy of the real contracts that an example may change.
  def guard_surfaces_contracts_copy
    Marshal.load(Marshal.dump(contracts))
  end

  def guard_surfaces_kinds(route_contract, route_name)
    TenantGuardSurfaces.pairs(contracts)
                       .filter_map { |contract, route, kind| kind if contract == route_contract && route == route_name }
  end

  def guard_cases_find(contract, route, mode, covers)
    TenantGuardCases::ALL.find do |kase|
      kase.contract == contract && kase.route == route && kase.mode == mode && kase.covers == covers
    end
  end

  describe "TenantGuardSurfaces.pairs" do
    it "R7 reservations prepare yields invoice_id, operation_id, idempotency_key and entry_id" do
      # "reservations prepare yields invoice_id, operation_id, idempotency_key and entry_id."
      expect(guard_surfaces_kinds(:reservations, :prepare))
        .to contain_exactly(:invoice_id, :operation_id, :idempotency_key, :entry_id)
    end

    it "R7 entry_api update and bulk_delete, and entry_snapshots deliver, yield entry_id and idempotency_key" do
      # "entry_api update and bulk_delete yield entry_id and idempotency_key."
      # "entry_snapshots deliver yields entry_id and idempotency_key."
      [%i[entry_api update], %i[entry_api bulk_delete], %i[entry_snapshots deliver]].each do |contract, route|
        expect(guard_surfaces_kinds(contract, route)).to contain_exactly(:entry_id, :idempotency_key), "#{contract} #{route}"
      end
    end

    it "R7 detach_entries yields operation_id and idempotency_key and nothing for its agent_id path param" do
      # "`operation_id` maps to both operation id and idempotency key, because idempotency.yml
      # `key_sources.reservations.key` is "operation_id in the body"."
      expect(guard_surfaces_kinds(:reservations, :detach_entries)).to contain_exactly(:operation_id, :idempotency_key)
    end

    it "R4 R7 handoff settle, stop_applying, drain, reference show and entry_api index each yield one no-identifier entry" do
      # "handoff settle, stop_applying and drain, reference show, and entry_api index yield none."
      # "A route carrying none of these gets a no-identifier entry."
      [%i[handoff settle], %i[handoff stop_applying], %i[handoff drain], %i[reference show], %i[entry_api index]]
        .each do |contract, route|
          expect(guard_surfaces_kinds(contract, route)).to eq([:none]), "#{contract} #{route}"
        end
      expect(TenantGuardSurfaces.pairs(contracts).select { |contract, _route, _kind| contract == :handoff })
        .to contain_exactly(%i[handoff settle none], %i[handoff stop_applying none], %i[handoff drain none])
    end

    # "An unrecognised route field raises instead of being read as carrying no identifier"
    it "R3 raises UnknownFieldError for an unrecognised route key rather than reading the route as no identifier" do
      changed = guard_surfaces_contracts_copy
      # A handoff route carries no identifier today, so a silently ignored key would leave it looking safe.
      changed[:handoff]["routes"]["settle"]["extra_field"] = ["entry_id"]

      expect { TenantGuardSurfaces.pairs(changed) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /extra_field/)
      expect { TenantGuardSurfaces.uncovered(contracts: changed, cases: TenantGuardCases::ALL) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /extra_field/)
    end

    # "Every other name must be on an explicit non-identifier list: `company_id`, `project_id`, `user_id`, `agent_id`,
    # `generation`, `disposition`, `through`, `from`, `to`, `project_ids`, `schema_version`, and the entry_api
    # `entry_*_fields` body fields. An unlisted name raises."
    it "R11 raises UnknownFieldError for an unlisted reservations request field and an unlisted snapshot entry field" do
      request_field = guard_surfaces_contracts_copy
      request_field[:reservations]["routes"]["prepare"]["request_fields"] << "tenant_ref"

      expect { TenantGuardSurfaces.pairs(request_field) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
      expect { TenantGuardSurfaces.uncovered(contracts: request_field, cases: TenantGuardCases::ALL) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)

      snapshot_field = guard_surfaces_contracts_copy
      snapshot_field[:entry_snapshots]["entry_fields"] << "tenant_ref"

      expect { TenantGuardSurfaces.pairs(snapshot_field) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
    end
  end

  describe "TenantGuardSurfaces.pairs on extra query and snapshot envelope names" do
    it "reports an identifier added to the reference show query string, and raises on an unlisted one" do
      with_invoice = guard_surfaces_contracts_copy
      with_invoice[:reference]["routes"]["show"]["query"] = "project_ids=1,2&invoice_id=601 (a comma-separated list)"

      expect(TenantGuardSurfaces.uncovered(contracts: with_invoice, cases: TenantGuardCases::ALL)[:pairs])
        .to eq([%i[reference show invoice_id]])

      with_unlisted = guard_surfaces_contracts_copy
      with_unlisted[:reference]["routes"]["show"]["query"] = "project_ids=1,2&tenant_ref=1"

      expect { TenantGuardSurfaces.pairs(with_unlisted) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
    end

    it "reads the snapshot item_fields and batch_fields, reporting an added identifier and raising on an unlisted name" do
      with_invoice = guard_surfaces_contracts_copy
      with_invoice[:entry_snapshots]["item_fields"] << "invoice_id"

      expect(TenantGuardSurfaces.uncovered(contracts: with_invoice, cases: TenantGuardCases::ALL)[:pairs])
        .to eq([%i[entry_snapshots deliver invoice_id]])

      with_unlisted = guard_surfaces_contracts_copy
      with_unlisted[:entry_snapshots]["batch_fields"] << "tenant_ref"

      expect { TenantGuardSurfaces.pairs(with_unlisted) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
    end
  end

  describe "TenantGuardSurfaces.pairs without a key source" do
    it "raises when a contract with write routes has no idempotency key source, instead of dropping its key pairs" do
      changed = guard_surfaces_contracts_copy
      changed[:idempotency]["key_sources"].delete("entry_api")

      expect { TenantGuardSurfaces.pairs(changed) }
        .to raise_error(TenantGuardSurfaces::UnknownFieldError, /entry_api\.\w+ is a write route/)
    end
  end

  describe "TenantGuardSurfaces.uncovered" do
    # "The real contracts against `TenantGuardCases` give an empty uncovered set."
    it "R1 the real contracts against TenantGuardCases::ALL leave no route and no pair uncovered" do
      expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL)).to eq(routes: [], pairs: [])
      expect(TenantGuardCases::ALL.map(&:mode).uniq - %i[probe replay]).to be_empty
    end

    # "Read the `routes:` map of every contract in `TimekeepingContract::CONTRACT_NAMES`, and fail when there are zero routes."
    it "R2 raises NoRoutesError when every contract's routes map is empty instead of reporting nothing uncovered" do
      changed = guard_surfaces_contracts_copy
      changed.each_value { |contract| contract["routes"] = {} if contract.key?("routes") }

      expect { TenantGuardSurfaces.uncovered(contracts: changed, cases: TenantGuardCases::ALL) }
        .to raise_error(TenantGuardSurfaces::NoRoutesError)
    end

    # "A route, or a route and identifier pair, with no case fails the guard."
    it "R1 reports an extra entry_api route that has no case as an uncovered route" do
      changed = guard_surfaces_contracts_copy
      changed[:entry_api]["routes"]["export"] = { "method" => "GET", "path" => "/v1/companies/{company_id}/entries/export" }

      report = TenantGuardSurfaces.uncovered(contracts: changed, cases: TenantGuardCases::ALL)

      expect(report[:routes]).to eq([%i[entry_api export]])
      expect(report[:pairs]).to include(%i[entry_api export none])
    end

    # "An extra identifier on an existing route is reported."
    it "R1 reports an invoice id added to the entry_api show path as its one uncovered pair while the route stays covered" do
      changed = guard_surfaces_contracts_copy
      changed[:entry_api]["routes"]["show"]["path"] = "/v1/companies/{company_id}/invoices/{invoice_id}/entries/{entry_id}"

      expect(TenantGuardSurfaces.uncovered(contracts: changed, cases: TenantGuardCases::ALL))
        .to eq(routes: [], pairs: [%i[entry_api show invoice_id]])
    end

    # "`uncovered` counts a replay toward its pairs only for that listed set."
    # The listed set holds the key cases only: "Replays: the key cases of create, update, bulk_move, prepare,
    # mark_billed and detach_entries, and the entry_snapshots key case."
    it "R8 counts a replay only toward the listed key pairs, not the destroy key or the prepare operation_id" do
      replace_with_replay = lambda do |contract, route, kind, covers|
        kept = TenantGuardCases::ALL.reject do |kase|
          kase.contract == contract && kase.route == route && kase.covers.include?(kind)
        end
        replay = TenantGuardCases::Case.new(
          contract:, route:, mode: :replay, covers:, credential: TenantGuardCases::CREDENTIALS.fetch(contract),
          first: :owner, expected: { status: 404, reason: "not_found" }, headers: {}
        )
        TenantGuardSurfaces.uncovered(contracts:, cases: kept + [replay])[:pairs]
      end

      expect(replace_with_replay.call(:entry_api, :destroy, :idempotency_key, [:idempotency_key]))
        .to eq([%i[entry_api destroy idempotency_key]])
      expect(replace_with_replay.call(:reservations, :prepare, :operation_id, %i[operation_id idempotency_key]))
        .to eq([%i[reservations prepare operation_id]])
      expect(replace_with_replay.call(:entry_api, :create, :idempotency_key, [:idempotency_key]))
        .not_to include(%i[entry_api create idempotency_key])
    end

    it "R8 REPLAY_PAIRS holds exactly the key pairs of create, update, bulk_move, prepare, mark_billed, detach_entries and deliver" do
      expect(TenantGuardSurfaces::REPLAY_PAIRS).to contain_exactly(
        %i[entry_api create idempotency_key],
        %i[entry_api update idempotency_key],
        %i[entry_api bulk_move idempotency_key],
        %i[reservations prepare idempotency_key],
        %i[reservations mark_billed idempotency_key],
        %i[reservations detach_entries idempotency_key],
        %i[entry_snapshots deliver idempotency_key]
      )
      expect(TenantGuardSurfaces::REPLAY_PAIRS).to be_frozen
      expect(TenantGuardSurfaces::REPLAY_PAIRS).to all(be_frozen)
    end
  end

  describe "TenantGuardCases::ALL" do
    it "R9 every record holds a route, a known mode, its covered kinds, its contract's credential kind and which company runs first" do
      credential_by_contract = {
        entry_api: :user_token,
        reservations: :service_token,
        handoff: :service_token,
        entry_snapshots: :timekeeping_service,
        reference: :timekeeping_service
      }
      kinds = %i[entry_id invoice_id operation_id idempotency_key none]

      expect(TenantGuardCases::ALL).not_to be_empty
      TenantGuardCases::ALL.each do |kase|
        label = "#{kase.contract}.#{kase.route} #{kase.covers.inspect}"

        expect(TimekeepingContract.load(kase.contract).fetch("routes")).to have_key(kase.route.to_s), label
        expect(%i[probe replay]).to include(kase.mode), label
        expect(kase.covers).not_to be_empty, label
        expect(kase.covers - kinds).to be_empty, label
        expect(kase.credential).to eq(credential_by_contract.fetch(kase.contract)), label
        expect(%i[requester owner]).to include(kase.first), label
        # Replays run the owner's own request first, so its receipt exists before the requester replays it.
        expect(kase.first).to eq(:owner), label if kase.mode == :replay
      end
    end

    it "keeps the case table, every record and its nested values frozen" do
      expect(TenantGuardCases::ALL).to be_frozen
      TenantGuardCases::ALL.each do |kase|
        expect([kase, kase.covers, kase.expected, kase.headers]).to all(be_frozen)
        expect(kase.expected.fetch(:results, []) + kase.expected.fetch(:conflicts, [])).to all(be_frozen)
      end
    end

    it "R4 each handoff route has one probe covering only none that expects 401 unauthorized" do
      # "The handoff routes in `contracts/timekeeping/handoff.yml` (settle, stop_applying, drain) carry none of the
      # four kinds, and each still gets a case."
      expect(TenantGuardCases::ALL.filter_map { |kase| kase.route if kase.contract == :handoff })
        .to contain_exactly(:settle, :stop_applying, :drain)

      %i[settle stop_applying drain].each do |route|
        kase = TenantGuardCases::ALL.find { |candidate| candidate.contract == :handoff && candidate.route == route }

        expect(kase.mode).to eq(:probe), route.to_s
        expect(kase.covers).to eq([:none]), route.to_s
        # "Handoff routes: 401 `unauthorized`."
        expect(kase.expected).to include(status: 401, reason: "unauthorized"), route.to_s
      end
    end

    it "the bulk_move replay and the prepare, mark_billed and detach_entries operation probes expect 404 not_found" do
      cases = [
        guard_cases_find(:entry_api, :bulk_move, :replay, [:idempotency_key]),
        guard_cases_find(:reservations, :prepare, :probe, [:operation_id]),
        guard_cases_find(:reservations, :mark_billed, :probe, [:operation_id]),
        guard_cases_find(:reservations, :detach_entries, :probe, [:operation_id])
      ]

      cases.each do |kase|
        expect(kase.expected).to eq(status: 404, reason: "not_found")
      end
    end
  end

  describe "TenantGuardCases.expected_answer" do
    it "R9 names the owner's entry as not_found in bulk probes and the prepare entry conflict, and 404 on single-entry routes" do
      entry_probe = ->(contract, route) { guard_cases_find(contract, route, :probe, [:entry_id]) }

      # "Bulk probes: 200, with that entry's `result` set to `not_found`."
      %i[bulk_move bulk_delete].each do |route|
        answer = TenantGuardCases.expected_answer(entry_probe.call(:entry_api, route), owner: owner_ids)
        expect(answer).to include(status: 200, results: [{ entry_id: 1501, result: "not_found" }]), route.to_s
      end

      # "A foreign entry in prepare: 409 `conflict` with a `not_found` conflict for the entry_id."
      expect(TenantGuardCases.expected_answer(entry_probe.call(:reservations, :prepare), owner: owner_ids))
        .to include(status: 409, reason: "conflict", conflicts: [{ entry_id: 1501, reason: "not_found" }])

      # "entry_api single-entry routes: 404 `not_found`."
      %i[update destroy show].each do |route|
        answer = TenantGuardCases.expected_answer(entry_probe.call(:entry_api, route), owner: owner_ids)
        expect(answer).to include(status: 404, reason: "not_found"), route.to_s
      end
    end
  end

  describe "TenantGuardCases.valid_request and probe_request" do
    # Flattens a request into [location, text] leaves, with the path split into its segments so a swapped path
    # parameter shows as one changed leaf.
    def guard_cases_request_leaves(request)
      flatten = lambda do |value, at|
        case value
        when Hash then value.flat_map { |key, nested| flatten.call(nested, at + [key]) }
        when Array then value.each_with_index.flat_map { |nested, index| flatten.call(nested, at + [index]) }
        else [[at, value.to_s]]
        end
      end
      flatten.call(request.merge(path: request.fetch(:path).split("/")), []).to_h
    end

    # Where each identifier kind sits in a route's request, as a guard_cases_request_leaves location. Index 5 of a
    # split path is the parameter after /v1/companies/{company_id}/<collection>/.
    def guard_cases_swap_locations
      body_operation = [:body, "operation_id"]
      {
        %i[entry_api update entry_id] => [:path, 5],
        %i[entry_api destroy entry_id] => [:path, 5],
        %i[entry_api show entry_id] => [:path, 5],
        %i[entry_api destroy idempotency_key] => [:headers, "Idempotency-Key"],
        %i[entry_api bulk_move entry_id] => [:body, "entry_ids", 0],
        %i[entry_api bulk_delete entry_id] => [:body, "entry_ids", 0],
        %i[entry_api bulk_delete idempotency_key] => [:headers, "Idempotency-Key"],
        %i[reservations prepare invoice_id] => [:body, "invoice_id"],
        %i[reservations prepare entry_id] => [:body, "entries", 0],
        %i[reservations prepare operation_id] => body_operation,
        %i[reservations commit invoice_id] => [:body, "invoice_id"],
        %i[reservations commit operation_id] => body_operation,
        %i[reservations commit idempotency_key] => body_operation,
        %i[reservations abort invoice_id] => [:body, "invoice_id"],
        %i[reservations abort operation_id] => body_operation,
        %i[reservations abort idempotency_key] => body_operation,
        %i[reservations mark_billed invoice_id] => [:path, 5],
        %i[reservations mark_billed operation_id] => body_operation,
        %i[reservations detach_entries operation_id] => body_operation,
        %i[entry_snapshots deliver entry_id] => [:body, "snapshots", 0, "entry", "id"]
      }
    end

    # "Each case swaps in exactly one foreign identifier and keeps the others valid for the requesting company."
    it "R5 every identifier probe differs from the requester's valid request in exactly the owner's swapped identifier" do
      # The reservations key is the body operation_id, so its swapped value is the owner's operation id.
      owner_value = lambda do |kase|
        kind = kase.covers.first
        kind = :operation_id if kind == :idempotency_key && kase.contract == :reservations
        { entry_id: "1501", invoice_id: "1601", operation_id: "op-owner-0001", idempotency_key: "key-owner-0001" }
          .fetch(kind)
      end
      probes = TenantGuardCases::ALL.select { |kase| kase.mode == :probe && kase.covers != [:none] }
      expect(probes).not_to be_empty

      probes.each do |kase|
        label = "#{kase.contract} #{kase.route} #{kase.covers.inspect}"
        valid = guard_cases_request_leaves(TenantGuardCases.valid_request(kase, ids: requester_ids))
        probe = guard_cases_request_leaves(TenantGuardCases.probe_request(kase, requester: requester_ids, owner: owner_ids))

        expect(probe.keys).to match_array(valid.keys), label
        changed = probe.reject { |at, text| valid[at] == text }
        expect(changed.size).to eq(1), "#{label} changed #{changed.inspect}"
        expect(changed.values.first).to eq(owner_value.call(kase)), label
        expect(probe.values).not_to include("1101"), "#{label} must keep the requester's company"
        # Every kind the probe claims to cover must live at the one location it changed, so a probe cannot claim
        # a kind whose field it leaves as the requester's.
        expected_locations = kase.covers.map { |kind| guard_cases_swap_locations.fetch([kase.contract, kase.route, kind]) }
        expect(expected_locations.uniq).to eq([changed.keys.first]), label
      end
    end

    it "R5 destroy and bulk_delete key probes send the requester's own entries with the three replay-only headers and the owner's key" do
      %i[destroy bulk_delete].each do |route|
        kase = guard_cases_find(:entry_api, route, :probe, [:idempotency_key])

        # "Probes: destroy and bulk_delete key cases send the requester's own entry ids with `Idempotency-Replay: only`,
        # `If-Match: replay-only` and `Ownership-Generation: replay-only`."
        expect(kase).not_to be_nil, route.to_s
        request = TenantGuardCases.probe_request(kase, requester: requester_ids, owner: owner_ids)

        expect(request.fetch(:headers)).to include(
          "Idempotency-Replay" => "only", "If-Match" => "replay-only",
          "Ownership-Generation" => "replay-only", "Idempotency-Key" => "key-owner-0001"
        )
        expect(request.to_s).not_to include("1501")
        expect(request.to_s).not_to include("1502")
      end
    end

    it "builds a no-identifier probe equal to the requester's valid request" do
      no_identifier = TenantGuardCases::ALL.select { |kase| kase.covers == [:none] }
      expect(no_identifier.map { |kase| [kase.contract, kase.route] }).to contain_exactly(
        %i[entry_api index], %i[reference show], %i[handoff settle], %i[handoff stop_applying], %i[handoff drain]
      )

      no_identifier.each do |kase|
        expect(TenantGuardCases.probe_request(kase, requester: requester_ids, owner: owner_ids))
          .to eq(TenantGuardCases.valid_request(kase, ids: requester_ids)), "#{kase.contract} #{kase.route}"
      end
    end

    # "For a replay, it takes the other company's recorded request and replaces only the company and the credential."
    it "R10 replays a recorded snapshot batch with only each entry's company_id and the Authorization header replaced" do
      kase = guard_cases_find(:entry_snapshots, :deliver, :replay, [:idempotency_key])
      built = TenantGuardCases.valid_request(kase, ids: owner_ids)
      recorded = built.merge(headers: built.fetch(:headers).merge("Authorization" => "Bearer owner-service"))
      original = Marshal.load(Marshal.dump(recorded))

      replay = TenantGuardCases.replay_request(recorded, company_id: 101, authorization: "Bearer requester-service")

      expected_body = Marshal.load(Marshal.dump(recorded.fetch(:body)))
      expected_body.fetch("snapshots").each { |snapshot| snapshot.fetch("entry")["company_id"] = 101 }
      expect(recorded.dig(:body, "snapshots", 0, "entry", "company_id")).to eq(1101)
      expect(replay).to eq(
        method: "POST", path: "/internal/v1/timekeeping/entry-snapshots",
        headers: { "Idempotency-Key" => "key-owner-0001", "Authorization" => "Bearer requester-service" },
        body: expected_body
      )
      expect(recorded).to eq(original)
    end

    it "builds delivery baseline, probe and replay batches that the snapshot parser accepts" do
      %i[probe replay].each do |mode|
        covers = mode == :probe ? [:entry_id] : [:idempotency_key]
        kase = guard_cases_find(:entry_snapshots, :deliver, mode, covers)
        baseline = TenantGuardCases.valid_request(kase, ids: requester_ids)
        probe = TenantGuardCases.probe_request(kase, requester: requester_ids, owner: owner_ids)
        replay = TenantGuardCases.replay_request(TenantGuardCases.valid_request(kase, ids: owner_ids),
                                                 company_id: 101, authorization: "Bearer requester-token")

        [baseline, probe, replay].each do |request|
          expect(Timekeeping::SnapshotBatch.parse(request.fetch(:body))).not_to be_nil, mode.to_s
        end
      end
    end

    it "update and destroy entry requests send If-Match with the entry's version, and a delivered snapshot names its user" do
      %i[update destroy].each do |route|
        request = TenantGuardCases.valid_request(guard_cases_find(:entry_api, route, :probe, [:entry_id]), ids: requester_ids)

        expect(request.fetch(:path)).to eq("/v1/companies/101/entries/501"), route.to_s
        expect(request.fetch(:headers)).to include("If-Match" => "3"), route.to_s
      end

      deliver = TenantGuardCases.valid_request(guard_cases_find(:entry_snapshots, :deliver, :probe, [:entry_id]),
                                               ids: requester_ids)
      entry = deliver.fetch(:body).fetch("snapshots").first.fetch("entry")
      expect(entry).to include("id" => 501, "company_id" => 101, "user_id" => 201, "version" => 3)
    end
  end

  describe "TenantGuardCases.replay_request" do
    # "For a replay, it takes the other company's recorded request and replaces only the company and the credential."
    it "R10 keeps the other company's key and body and replaces only the path company and the credential" do
      recorded = {
        method: "PATCH",
        path: "/v1/companies/22/entries/505",
        headers: { "Authorization" => "Bearer owner-token", "Idempotency-Key" => "owner-key-1", "If-Match" => "3" },
        body: { "project_id" => 707, "note" => "owner note" }
      }.freeze

      replay = TenantGuardCases.replay_request(recorded, company_id: 11, authorization: "Bearer requester-token")

      expect(replay[:method]).to eq("PATCH")
      expect(replay[:path]).to eq("/v1/companies/11/entries/505")
      expect(replay[:headers]).to eq(
        "Authorization" => "Bearer requester-token", "Idempotency-Key" => "owner-key-1", "If-Match" => "3"
      )
      expect(replay[:body]).to eq("project_id" => 707, "note" => "owner note")
      expect(recorded[:headers]["Authorization"]).to eq("Bearer owner-token")
    end

    it "R10 replaces only the path company and the Authorization header of the owner's recorded update, leaving it unchanged" do
      kase = guard_cases_find(:entry_api, :update, :replay, [:idempotency_key])
      built = TenantGuardCases.valid_request(kase, ids: owner_ids)
      recorded = built.merge(headers: built.fetch(:headers).merge("Authorization" => "Bearer owner-token"))
      snapshot = Marshal.load(Marshal.dump(recorded))

      replay = TenantGuardCases.replay_request(recorded, company_id: 101, authorization: "Bearer requester-token")

      expect(replay.fetch(:method)).to eq(recorded.fetch(:method))
      expect(replay.fetch(:path)).to eq("/v1/companies/101/entries/1501")
      expect(replay.fetch(:body)).to eq(recorded.fetch(:body))
      expect(replay.fetch(:headers)).to eq(recorded.fetch(:headers).merge("Authorization" => "Bearer requester-token"))
      expect(replay.fetch(:headers)).to include("Idempotency-Key" => "key-owner-0001")
      expect(recorded).to eq(snapshot)
    end
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping tenant guard surfaces: unlisted request field" do
  it "R11 raises on an unlisted reservations request field instead of reading it as no identifier" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    changed = Marshal.load(Marshal.dump(contracts))
    changed[:reservations]["routes"]["prepare"]["request_fields"] << "tenant_ref"

    # "Every other name must be on an explicit non-identifier list: `company_id`, `project_id`, `user_id`,
    # `agent_id`, `generation`, `disposition`, `through`, `from`, `to`, `project_ids`, `schema_version`, and the
    # entry_api `entry_*_fields` body fields. An unlisted name raises."
    expect { TenantGuardSurfaces.pairs(changed) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
    expect { TenantGuardSurfaces.uncovered(contracts: changed, cases: TenantGuardCases::ALL) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: unrecognised route key" do
  it "R3 raises on an unrecognised route key instead of reading the route as carrying no identifier" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    changed = Marshal.load(Marshal.dump(contracts))
    # A handoff route carries no identifier today, so a silently ignored key would leave it looking safe.
    changed[:handoff]["routes"]["settle"]["extra_field"] = ["entry_id"]

    # "An unrecognised route field raises instead of being read as carrying no identifier"
    expect { TenantGuardSurfaces.pairs(changed) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /extra_field/)
  end
end

RSpec.describe "Timekeeping tenant guard cases: handoff routes" do
  it "R4 gives each handoff route a no-identifier case that expects 401 unauthorized" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }

    # "The handoff routes in `contracts/timekeeping/handoff.yml` (settle, stop_applying, drain) carry none of the
    # four kinds, and each still gets a case. The case asserts from the contract that the route carries no such
    # identifier."
    expect(TenantGuardSurfaces.pairs(contracts).select { |contract, _route, _kind| contract == :handoff })
      .to contain_exactly([:handoff, :settle, :none], [:handoff, :stop_applying, :none], [:handoff, :drain, :none])

    %i[settle stop_applying drain].each do |route|
      cases = TenantGuardCases::ALL.select { |kase| kase.contract == :handoff && kase.route == route }
      expect(cases.size).to eq(1), "expected one case for handoff #{route}"
      kase = cases.first
      expect(kase.mode).to eq(:probe)
      expect(kase.covers).to eq([:none])
      # "Handoff routes: 401 `unauthorized`."
      expect(kase.expected).to include(status: 401, reason: "unauthorized")
    end
  end
end

RSpec.describe "Timekeeping tenant guard cases: replay request" do
  it "R10 replay keeps the other company's key and body and replaces only the path company and the credential" do
    recorded = {
      method: "PATCH",
      path: "/v1/companies/22/entries/505",
      headers: { "Authorization" => "Bearer owner-token", "Idempotency-Key" => "owner-key-1", "If-Match" => "3" },
      body: { "project_id" => 707, "note" => "owner note" }
    }.freeze

    replay = TenantGuardCases.replay_request(recorded, company_id: 11, authorization: "Bearer requester-token")

    # "For a replay, it takes the other company's recorded request and replaces only the company and the credential."
    expect(replay[:method]).to eq("PATCH")
    expect(replay[:path]).to eq("/v1/companies/11/entries/505")
    expect(replay[:headers]).to eq(
      "Authorization" => "Bearer requester-token", "Idempotency-Key" => "owner-key-1", "If-Match" => "3"
    )
    expect(replay[:body]).to eq("project_id" => 707, "note" => "owner note")
    expect(recorded[:headers]["Authorization"]).to eq("Bearer owner-token")
  end
end

RSpec.describe "Timekeeping tenant guard cases: probe requests" do
  it "R5 every identifier probe differs from the requester's valid request in exactly one owner identifier" do
    requester = {
      company_id: 11, user_id: 111, project_id: 1101, agent_id: 1102, entry_ids: [1103, 1104],
      entry_versions: { 1103 => 4, 1104 => 5 }, invoice_id: 1105, operation_id: "requester-operation",
      idempotency_key: "requester-key", generation: 2
    }
    owner = {
      company_id: 22, user_id: 222, project_id: 2201, agent_id: 2202, entry_ids: [2203, 2204],
      entry_versions: { 2203 => 7, 2204 => 8 }, invoice_id: 2205, operation_id: "owner-operation",
      idempotency_key: "owner-key", generation: 2
    }
    owner_value = {
      entry_id: owner[:entry_ids].first, invoice_id: owner[:invoice_id],
      operation_id: owner[:operation_id], idempotency_key: owner[:idempotency_key]
    }
    leaves = lambda do |value, prefix = []|
      case value
      when Hash then value.flat_map { |key, nested| leaves.call(nested, prefix + [key]) }
      when Array then value.each_with_index.flat_map { |nested, index| leaves.call(nested, prefix + [index]) }
      else [[prefix, value]]
      end
    end

    # Splits the path into segments, so a swapped path parameter shows as its own leaf.
    split_path = ->(request) { request.merge(path: request.fetch(:path).split("/")) }

    probes = TenantGuardCases::ALL.select { |kase| kase.mode == :probe && kase.covers != [:none] }
    expect(probes).not_to be_empty

    probes.each do |kase|
      label = "#{kase.contract} #{kase.route} #{kase.covers.inspect}"
      valid = leaves.call(split_path.call(TenantGuardCases.valid_request(kase, ids: requester))).to_h
      probe = leaves.call(split_path.call(TenantGuardCases.probe_request(kase, requester:, owner:))).to_h

      # "Each case swaps in exactly one foreign identifier and keeps the others valid for the requesting company."
      expect(probe.keys).to match_array(valid.keys), label
      changed = probe.reject { |path, value| valid[path] == value }
      expect(changed.size).to eq(1), "#{label} changed #{changed.inspect}"
      expected_values = kase.covers.map { |kind| owner_value.fetch(kind) }
      expect(expected_values.map(&:to_s)).to include(changed.values.first.to_s), label
    end
  end
end

RSpec.describe "Timekeeping tenant guard replay list" do
  it "REPLAY_PAIRS holds exactly the issue's listed idempotency key replays" do
    # "Replays: the key cases of create, update, bulk_move, prepare, mark_billed and detach_entries,
    # and the entry_snapshots key case."
    expect(TenantGuardSurfaces::REPLAY_PAIRS).to match_array(
      [
        %i[entry_api create idempotency_key],
        %i[entry_api update idempotency_key],
        %i[entry_api bulk_move idempotency_key],
        %i[reservations prepare idempotency_key],
        %i[reservations mark_billed idempotency_key],
        %i[reservations detach_entries idempotency_key],
        %i[entry_snapshots deliver idempotency_key]
      ]
    )
    expect(TenantGuardSurfaces::REPLAY_PAIRS).to be_frozen
    expect(TenantGuardSurfaces::REPLAY_PAIRS).to all(be_frozen)
  end
end

RSpec.describe "Timekeeping tenant guard replay coverage" do
  let(:contracts) { TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) } }

  def replay_in_place_of(pair)
    contract, route, kind = pair
    kept = TenantGuardCases::ALL.reject { |kase| kase.contract == contract && kase.route == route && kase.covers.include?(kind) }
    replay = TenantGuardCases::Case.new(
      contract:, route:, mode: :replay, covers: [kind].freeze, credential: :user_token, first: :owner,
      expected: { status: 404, reason: "not_found" }.freeze, headers: {}.freeze
    )
    kept + [replay]
  end

  it "a replay for a pair outside the replay list does not cover it" do
    # "`uncovered` counts a replay toward its pairs only for that listed set."
    [%i[entry_api destroy idempotency_key], %i[reservations prepare operation_id]].each do |pair|
      result = TenantGuardSurfaces.uncovered(contracts:, cases: replay_in_place_of(pair))

      expect(result[:pairs]).to include(pair)
    end

    listed = %i[entry_api create idempotency_key]
    result = TenantGuardSurfaces.uncovered(contracts:, cases: replay_in_place_of(listed))
    expect(result[:pairs]).not_to include(listed)
  end
end

RSpec.describe "Timekeeping tenant guard replay request" do
  it "replay_request keeps the recorded key and body and replaces only the company and the credential" do
    recorded = {
      method: "POST",
      path: "/v1/companies/702/entries",
      headers: { "Authorization" => "Bearer owner-token", "Idempotency-Key" => "owner-key-9f1c" },
      body: { "project_id" => 811, "work_date" => "2026-01-05", "duration" => 60.0, "note" => "owner note" }
    }.freeze

    # "For a replay, it takes the other company's recorded request and replaces only the company and the credential."
    replay = TenantGuardCases.replay_request(recorded, company_id: 301, authorization: "Bearer requester-token")

    expect(replay[:method]).to eq("POST")
    expect(replay[:path]).to eq("/v1/companies/301/entries")
    expect(replay[:headers]).to eq(
      "Authorization" => "Bearer requester-token", "Idempotency-Key" => "owner-key-9f1c"
    )
    expect(replay[:body]).to eq(recorded[:body])
    expect(recorded[:path]).to eq("/v1/companies/702/entries")
    expect(recorded[:headers]["Authorization"]).to eq("Bearer owner-token")
  end
end

RSpec.describe "Timekeeping tenant guard coverage of the real contracts" do
  it "the real contracts against TenantGuardCases give an empty uncovered set" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }

    # "A route, or a route and identifier pair, with no case fails the guard."
    expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL)).to eq(routes: [], pairs: [])
    expect(TenantGuardCases::ALL.map(&:mode).uniq - %i[probe replay]).to be_empty
  end
end

RSpec.describe "Timekeeping tenant guard surfaces" do
  # "Each case swaps in exactly one foreign identifier and keeps the others valid for the requesting company."
  it "R5 every identifier probe swaps in exactly one owner identifier and keeps every other value the requester's" do
    requester = {
      company_id: 101, user_id: 201, project_id: 301, agent_id: 401, entry_ids: [501, 502],
      entry_versions: { 501 => 3, 502 => 4 }, invoice_id: 601, operation_id: "op-requester-0001",
      idempotency_key: "key-requester-0001", generation: 2
    }
    owner = {
      company_id: 1101, user_id: 1201, project_id: 1301, agent_id: 1401, entry_ids: [1501, 1502],
      entry_versions: { 1501 => 7, 1502 => 8 }, invoice_id: 1601, operation_id: "op-owner-0001",
      idempotency_key: "key-owner-0001", generation: 2
    }
    owner_value_for = {
      entry_id: "1501", invoice_id: "1601", operation_id: "op-owner-0001", idempotency_key: "key-owner-0001"
    }
    # Flattens a request into [location, text] leaves; the path is split into its segments.
    leaves = lambda do |value, location = []|
      case value
      when Hash then value.flat_map { |key, nested| leaves.call(nested, location + [key]) }
      when Array then value.each_with_index.flat_map { |nested, index| leaves.call(nested, location + [index]) }
      else [[location, value.to_s]]
      end
    end
    flatten_request = lambda do |request|
      segments = request.fetch(:path).split("/").each_with_index.map { |segment, index| [[:path, index], segment] }
      segments + leaves.call(request.fetch(:headers), [:headers]) + leaves.call(request.fetch(:body), [:body]) +
        [[[:method], request.fetch(:method).to_s]]
    end

    probes = TenantGuardCases::ALL.select { |kase| kase.mode == :probe && kase.covers != [:none] }
    expect(probes).not_to be_empty

    probes.each do |kase|
      valid = flatten_request.call(TenantGuardCases.valid_request(kase, ids: requester)).to_h
      probe = flatten_request.call(TenantGuardCases.probe_request(kase, requester:, owner:)).to_h
      label = "#{kase.contract} #{kase.route} #{kase.covers.inspect}"

      expect(probe.keys).to match_array(valid.keys), label
      changed = probe.reject { |location, text| valid[location] == text }
      expect(changed.size).to eq(1), "#{label} changed #{changed.inspect}"
      expect(changed.values.first).to eq(owner_value_for.fetch(kase.covers.first)), label
      expect(probe.values).not_to include("1101"), "#{label} must keep the requester's company"
    end
  end
end

RSpec.describe "Timekeeping tenant guard surfaces" do
  # "For a replay, it takes the other company's recorded request and replaces only the company and the credential."
  it "R10 a replay of the owner's recorded update changes only the path company and the Authorization header" do
    owner = {
      company_id: 1101, user_id: 1201, project_id: 1301, agent_id: 1401, entry_ids: [1501, 1502],
      entry_versions: { 1501 => 7, 1502 => 8 }, invoice_id: 1601, operation_id: "op-owner-0001",
      idempotency_key: "key-owner-0001", generation: 2
    }
    kase = TenantGuardCases::ALL.find do |candidate|
      candidate.contract == :entry_api && candidate.route == :update && candidate.mode == :replay
    end
    expect(kase).not_to be_nil

    owner_request = TenantGuardCases.valid_request(kase, ids: owner)
    recorded = owner_request.merge(headers: owner_request.fetch(:headers).merge("Authorization" => "Bearer owner-token"))

    replay = TenantGuardCases.replay_request(recorded, company_id: 101, authorization: "Bearer requester-token")

    expect(replay.fetch(:path)).to eq("/v1/companies/101/entries/1501")
    expect(replay.fetch(:method)).to eq(recorded.fetch(:method))
    expect(replay.fetch(:body)).to eq(recorded.fetch(:body))
    expect(replay.fetch(:headers).fetch("Authorization")).to eq("Bearer requester-token")
    expect(replay.fetch(:headers).except("Authorization")).to eq(recorded.fetch(:headers).except("Authorization"))
    expect(replay.fetch(:headers).values.map(&:to_s)).to include("key-owner-0001")
  end
end

RSpec.describe "Timekeeping tenant guard surfaces" do
  it "expected answers name the owner's entry as not_found in bulk probes and the prepare entry conflict" do
    owner = {
      company_id: 1101, user_id: 1201, project_id: 1301, agent_id: 1401, entry_ids: [1501, 1502],
      entry_versions: { 1501 => 7, 1502 => 8 }, invoice_id: 1601, operation_id: "op-owner-0001",
      idempotency_key: "key-owner-0001", generation: 2
    }
    entry_probe = lambda do |contract, route|
      TenantGuardCases::ALL.find do |kase|
        kase.contract == contract && kase.route == route && kase.mode == :probe && kase.covers.include?(:entry_id)
      end
    end

    # "Bulk probes: 200, with that entry's `result` set to `not_found`."
    %i[bulk_move bulk_delete].each do |route|
      answer = TenantGuardCases.expected_answer(entry_probe.call(:entry_api, route), owner:)
      expect(answer).to include(status: 200, results: [{ entry_id: 1501, result: "not_found" }]), route.to_s
    end

    # "A foreign entry in prepare: 409 `conflict` with a `not_found` conflict for the entry_id."
    prepare = TenantGuardCases.expected_answer(entry_probe.call(:reservations, :prepare), owner:)
    expect(prepare).to include(status: 409, reason: "conflict", conflicts: [{ entry_id: 1501, reason: "not_found" }])

    # "entry_api single-entry routes: 404 `not_found`."
    %i[update destroy show].each do |route|
      answer = TenantGuardCases.expected_answer(entry_probe.call(:entry_api, route), owner:)
      expect(answer).to include(status: 404, reason: "not_found"), route.to_s
    end
  end
end

RSpec.describe "Timekeeping tenant guard surfaces" do
  # "A route, or a route and identifier pair, with no case fails the guard."
  it "R1 the real contracts against TenantGuardCases leave no route or foreign identifier pair uncovered" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }

    expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL)).to eq(routes: [], pairs: [])

    # "The handoff routes in `contracts/timekeeping/handoff.yml` (settle, stop_applying, drain) carry none of the
    # four kinds, and each still gets a case."
    handoff_cases = TenantGuardCases::ALL.select { |kase| kase.contract == :handoff }
    expect(handoff_cases.map(&:route)).to match_array(%i[settle stop_applying drain])
    handoff_cases.each do |kase|
      expect(kase.covers).to eq([:none])
      expect(kase.expected).to include(status: 401, reason: "unauthorized")
    end
  end
end

RSpec.describe "TenantGuardSurfaces.pairs on reservations prepare" do
  it "R7 pairs: reservations prepare yields invoice_id, operation_id, idempotency_key and entry_id" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }

    kinds = TenantGuardSurfaces.pairs(contracts)
                               .filter_map { |contract, route, kind| kind if contract == :reservations && route == :prepare }

    # "reservations prepare yields invoice_id, operation_id, idempotency_key and entry_id."
    expect(kinds).to contain_exactly(:invoice_id, :operation_id, :idempotency_key, :entry_id)
  end
end

RSpec.describe "TenantGuardSurfaces.pairs on entry and snapshot write routes" do
  it "R7 pairs: entry_api update and bulk_delete, and entry_snapshots deliver, yield entry_id and idempotency_key" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    pairs = TenantGuardSurfaces.pairs(contracts)

    # "entry_api update and bulk_delete yield entry_id and idempotency_key."
    # "entry_snapshots deliver yields entry_id and idempotency_key."
    [[:entry_api, :update], [:entry_api, :bulk_delete], [:entry_snapshots, :deliver]].each do |contract_name, route_name|
      kinds = pairs.filter_map { |contract, route, kind| kind if contract == contract_name && route == route_name }

      expect(kinds).to contain_exactly(:entry_id, :idempotency_key), "#{contract_name} #{route_name}"
    end
  end
end

RSpec.describe "TenantGuardSurfaces.pairs on routes that carry no identifier" do
  it "R4 R7 pairs: handoff settle, stop_applying, drain, reference show and entry_api index each yield exactly one no-identifier entry" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    pairs = TenantGuardSurfaces.pairs(contracts)

    # "handoff settle, stop_applying and drain, reference show, and entry_api index yield none."
    # "A route carrying none of these gets a no-identifier entry."
    [[:handoff, :settle], [:handoff, :stop_applying], [:handoff, :drain], [:reference, :show], [:entry_api, :index]]
      .each do |contract_name, route_name|
        kinds = pairs.filter_map { |contract, route, kind| kind if contract == contract_name && route == route_name }

        expect(kinds).to eq([:none]), "#{contract_name} #{route_name}"
      end
  end
end

RSpec.describe "TenantGuardSurfaces.pairs on reservations detach_entries" do
  it "R7 pairs: detach_entries yields operation_id and idempotency_key and nothing for its agent_id path param" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }

    kinds = TenantGuardSurfaces.pairs(contracts)
                               .filter_map { |contract, route, kind| kind if contract == :reservations && route == :detach_entries }

    # "`operation_id` maps to both operation id and idempotency key, because idempotency.yml
    # `key_sources.reservations.key` is "operation_id in the body"."
    expect(kinds).to contain_exactly(:operation_id, :idempotency_key)
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered with no routes" do
  it "R2 uncovered: contracts whose routes maps are all empty raise NoRoutesError" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }.deep_dup
    contracts.each_value { |contract| contract["routes"] = {} if contract.key?("routes") }

    # "Read the `routes:` map of every contract in `TimekeepingContract::CONTRACT_NAMES`, and fail when there are zero routes."
    expect { TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL) }
      .to raise_error(TenantGuardSurfaces::NoRoutesError)
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered with an unrecognised route key" do
  it "R3 uncovered: an unrecognised key on a handoff route raises UnknownFieldError instead of reading the route as carrying no identifier" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }.deep_dup
    contracts[:handoff]["routes"]["settle"]["extra_field"] = ["invoice_ref"]

    # "An unrecognised route field raises instead of being read as carrying no identifier"
    expect { TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /extra_field/)
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered with an unlisted request field" do
  it "R11 uncovered: an unlisted request field on a reservations route raises UnknownFieldError" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }.deep_dup
    contracts[:reservations]["routes"]["commit"]["request_fields"] << "tenant_ref"

    # "Every other name must be on an explicit non-identifier list: ... An unlisted name raises."
    expect { TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered on the real contracts" do
  it "R1 uncovered: the real contracts against TenantGuardCases::ALL leave no route and no pair uncovered" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }

    # "The real contracts against `TenantGuardCases` give an empty uncovered set."
    expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL)).to eq(routes: [], pairs: [])
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered with an extra route" do
  it "R1 uncovered: an extra route with no case is reported under routes" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }.deep_dup
    contracts[:entry_api]["routes"]["archive"] = { "method" => "GET", "path" => "/v1/companies/{company_id}/archive" }

    # "A route, or a route and identifier pair, with no case fails the guard."
    expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL)[:routes])
      .to eq([[:entry_api, :archive]])
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered with an extra identifier" do
  it "R1 uncovered: an extra invoice_id path param on entry_api show is reported as its one uncovered pair" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }.deep_dup
    contracts[:entry_api]["routes"]["show"]["path"] = "/v1/companies/{company_id}/invoices/{invoice_id}/entries/{entry_id}"

    # "An extra identifier on an existing route is reported."
    expect(TenantGuardSurfaces.uncovered(contracts:, cases: TenantGuardCases::ALL))
      .to eq(routes: [], pairs: [[:entry_api, :show, :invoice_id]])
  end
end

RSpec.describe "TenantGuardSurfaces.uncovered with replays outside the replay list" do
  it "R8 uncovered: a replay for the destroy key or the prepare operation_id does not cover that pair" do
    contracts = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    outside = [[:entry_api, :destroy, :idempotency_key], [:reservations, :prepare, :operation_id]]

    cases = TenantGuardCases::ALL.map do |kase|
      covered = outside.any? { |contract, route, kind| kase.contract == contract && kase.route == route && kase.covers.include?(kind) }
      covered && kase.mode == :probe ? kase.with(mode: :replay) : kase
    end

    # "`uncovered` counts a replay toward its pairs only for that listed set."
    expect(TenantGuardSurfaces.uncovered(contracts:, cases:)[:pairs]).to include(*outside)
  end
end

RSpec.describe "TenantGuardSurfaces::REPLAY_PAIRS" do
  it "R8 REPLAY_PAIRS holds exactly the key pairs of create, update, bulk_move, prepare, mark_billed, detach_entries and deliver" do
    # "Replays: the key cases of create, update, bulk_move, prepare, mark_billed and detach_entries, and the
    # entry_snapshots key case."
    expect(TenantGuardSurfaces::REPLAY_PAIRS).to contain_exactly(
      [:entry_api, :create, :idempotency_key],
      [:entry_api, :update, :idempotency_key],
      [:entry_api, :bulk_move, :idempotency_key],
      [:reservations, :prepare, :idempotency_key],
      [:reservations, :mark_billed, :idempotency_key],
      [:reservations, :detach_entries, :idempotency_key],
      [:entry_snapshots, :deliver, :idempotency_key]
    )
    expect(TenantGuardSurfaces::REPLAY_PAIRS).to be_frozen
    expect(TenantGuardSurfaces::REPLAY_PAIRS).to all(be_frozen)
  end
end

RSpec.describe "TenantGuardCases::ALL handoff cases" do
  it "R4 cases: each handoff route has one probe covering only none that expects 401 unauthorized" do
    %i[settle stop_applying drain].each do |route|
      cases = TenantGuardCases::ALL.select { |kase| kase.contract == :handoff && kase.route == route }

      # "The handoff routes in `contracts/timekeeping/handoff.yml` (settle, stop_applying, drain) carry none of the
      # four kinds, and each still gets a case."
      expect(cases.size).to eq(1), route.to_s
      expect(cases.first.mode).to eq(:probe)
      expect(cases.first.covers).to eq([:none])
      # "Handoff routes: 401 `unauthorized`."
      expect(cases.first.expected).to include(status: 401, reason: "unauthorized")
    end
  end
end

RSpec.describe "TenantGuardCases.probe_request against valid_request" do
  it "R5 probe_request: every identifier probe differs from the requester's valid request in exactly the swapped identifier" do
    requester = {
      company_id: 101, user_id: 201, project_id: 301, agent_id: 401, entry_ids: [501, 502],
      entry_versions: { 501 => 7, 502 => 8 }, invoice_id: 601, operation_id: "op-a-1",
      idempotency_key: "key-a-1", generation: 2
    }
    owner = {
      company_id: 102, user_id: 202, project_id: 302, agent_id: 402, entry_ids: [551, 552],
      entry_versions: { 551 => 3, 552 => 4 }, invoice_id: 651, operation_id: "op-b-1",
      idempotency_key: "key-b-1", generation: 2
    }
    leaves = lambda do |value, prefix = []|
      case value
      when Hash then value.flat_map { |key, nested| leaves.call(nested, prefix + [key.to_s]) }
      when Array then value.each_with_index.flat_map { |nested, index| leaves.call(nested, prefix + [index]) }
      else [[prefix, value.to_s]]
      end
    end
    split_path = ->(request) { request.merge(path: request.fetch(:path).split("/")) }
    owner_value = lambda do |kase, kind|
      {
        entry_id: owner[:entry_ids].first, invoice_id: owner[:invoice_id], operation_id: owner[:operation_id],
        idempotency_key: kase.contract == :reservations ? owner[:operation_id] : owner[:idempotency_key]
      }.fetch(kind).to_s
    end

    probes = TenantGuardCases::ALL.select { |kase| kase.mode == :probe && kase.covers != [:none] }
    expect(probes).not_to be_empty

    probes.each do |kase|
      valid = leaves.call(split_path.call(TenantGuardCases.valid_request(kase, ids: requester))).to_h
      probe = leaves.call(split_path.call(TenantGuardCases.probe_request(kase, requester:, owner:))).to_h
      changed = probe.reject { |path, value| valid[path] == value }
      label = "#{kase.contract} #{kase.route} #{kase.covers.inspect}"

      # "Each case swaps in exactly one foreign identifier and keeps the others valid for the requesting company."
      expect(probe.keys).to match_array(valid.keys), label
      expect(changed.size).to eq(1), label
      expect(kase.covers.map { |kind| owner_value.call(kase, kind) }).to include(changed.values.first), label
    end
  end
end

RSpec.describe "TenantGuardCases.expected_answer for entry probes" do
  it "R9 expected_answer: bulk entry probes expect 200 with the owner's entry not_found and the prepare entry probe expects a not_found conflict for it" do
    owner = {
      company_id: 102, user_id: 202, project_id: 302, agent_id: 402, entry_ids: [551, 552],
      entry_versions: { 551 => 3, 552 => 4 }, invoice_id: 651, operation_id: "op-b-1",
      idempotency_key: "key-b-1", generation: 2
    }
    entry_probe = lambda do |contract, route|
      matches = TenantGuardCases::ALL.select do |kase|
        kase.contract == contract && kase.route == route && kase.mode == :probe && kase.covers == [:entry_id]
      end
      expect(matches.size).to eq(1), "#{contract} #{route}"
      matches.first
    end

    # "Bulk probes: 200, with that entry's `result` set to `not_found`."
    %i[bulk_move bulk_delete].each do |route|
      expect(TenantGuardCases.expected_answer(entry_probe.call(:entry_api, route), owner:))
        .to include(status: 200, results: [{ entry_id: 551, result: "not_found" }])
    end

    # "A foreign entry in prepare: 409 `conflict` with a `not_found` conflict for the entry_id."
    expect(TenantGuardCases.expected_answer(entry_probe.call(:reservations, :prepare), owner:))
      .to include(status: 409, reason: "conflict", conflicts: [{ entry_id: 551, reason: "not_found" }])
  end
end

RSpec.describe "TenantGuardCases.probe_request for replay-only key probes" do
  it "R5 probe_request: destroy and bulk_delete key probes send the requester's own entries with the three replay-only headers and the owner's key" do
    requester = {
      company_id: 101, user_id: 201, project_id: 301, agent_id: 401, entry_ids: [501, 502],
      entry_versions: { 501 => 7, 502 => 8 }, invoice_id: 601, operation_id: "op-a-1",
      idempotency_key: "key-a-1", generation: 2
    }
    owner = {
      company_id: 102, user_id: 202, project_id: 302, agent_id: 402, entry_ids: [551, 552],
      entry_versions: { 551 => 3, 552 => 4 }, invoice_id: 651, operation_id: "op-b-1",
      idempotency_key: "key-b-1", generation: 2
    }

    %i[destroy bulk_delete].each do |route|
      kase = TenantGuardCases::ALL.find do |candidate|
        candidate.contract == :entry_api && candidate.route == route && candidate.covers.include?(:idempotency_key)
      end

      # "Probes: destroy and bulk_delete key cases send the requester's own entry ids with `Idempotency-Replay: only`,
      # `If-Match: replay-only` and `Ownership-Generation: replay-only`."
      expect(kase.mode).to eq(:probe), route.to_s
      request = TenantGuardCases.probe_request(kase, requester:, owner:)
      headers = request.fetch(:headers).transform_keys(&:to_s)

      expect(headers).to include(
        "Idempotency-Replay" => "only", "If-Match" => "replay-only",
        "Ownership-Generation" => "replay-only", "Idempotency-Key" => "key-b-1"
      )
      expect(request.to_s).not_to include("551")
      expect(request.to_s).not_to include("552")
    end
  end
end

RSpec.describe "TenantGuardCases.replay_request" do
  it "R10 replay_request: replaces only the path company and the Authorization header of the owner's recorded update" do
    owner = {
      company_id: 102, user_id: 202, project_id: 302, agent_id: 402, entry_ids: [551, 552],
      entry_versions: { 551 => 3, 552 => 4 }, invoice_id: 651, operation_id: "op-b-1",
      idempotency_key: "key-b-1", generation: 2
    }
    kase = TenantGuardCases::ALL.find do |candidate|
      candidate.contract == :entry_api && candidate.route == :update && candidate.mode == :replay
    end
    built = TenantGuardCases.valid_request(kase, ids: owner)
    recorded = built.merge(headers: built.fetch(:headers).merge("Authorization" => "Bearer owner-token"))
    snapshot = Marshal.load(Marshal.dump(recorded))

    replay = TenantGuardCases.replay_request(recorded, company_id: 101, authorization: "Bearer requester-token")

    # "For a replay, it takes the other company's recorded request and replaces only the company and the credential."
    expect(replay.fetch(:method)).to eq(recorded.fetch(:method))
    expect(replay.fetch(:path)).to eq("/v1/companies/101/entries/551")
    expect(replay.fetch(:body)).to eq(recorded.fetch(:body))
    expect(replay.fetch(:headers)).to eq(recorded.fetch(:headers).merge("Authorization" => "Bearer requester-token"))
    expect(recorded).to eq(snapshot)
  end
end

RSpec.describe "Timekeeping tenant guard case records" do
  it "R9 cases: every record holds a route, a known mode, its covered kinds, its contract's credential kind and which company runs first" do
    credential_by_contract = {
      entry_api: :user_token,
      reservations: :service_token,
      handoff: :service_token,
      entry_snapshots: :timekeeping_service,
      reference: :timekeeping_service
    }
    kinds = %i[entry_id invoice_id operation_id idempotency_key none]
    cases = TenantGuardCases::ALL

    expect(cases).to be_frozen
    expect(cases).not_to be_empty
    cases.each do |kase|
      label = "#{kase.contract}.#{kase.route} #{kase.covers.inspect}"
      routes = TimekeepingContract.load(kase.contract).fetch("routes")

      expect(routes).to have_key(kase.route.to_s), label
      expect(%i[probe replay]).to include(kase.mode), label
      expect(kase.covers).to be_frozen, label
      expect(kase.covers).not_to be_empty, label
      expect(kase.covers - kinds).to be_empty, label
      expect(kase.credential).to eq(credential_by_contract.fetch(kase.contract)), label
      expect(%i[requester owner]).to include(kase.first), label
      # Replays run the owner's own request first, so its receipt exists before the requester replays it.
      expect(kase.first).to eq(:owner), label if kase.mode == :replay
    end
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: an extra route" do
  def guard_surfaces_contracts_copy
    real = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    Marshal.load(Marshal.dump(real))
  end

  # "A route, or a route and identifier pair, with no case fails the guard."
  it "R1 reports an extra entry_api route that has no case as an uncovered route" do
    contracts = guard_surfaces_contracts_copy
    contracts[:entry_api]["routes"]["export"] = { "method" => "GET", "path" => "/v1/companies/{company_id}/entries/export" }

    report = TenantGuardSurfaces.uncovered(contracts: contracts, cases: TenantGuardCases::ALL)

    expect(report[:routes]).to eq([%i[entry_api export]])
    expect(report[:pairs]).to include(%i[entry_api export none])
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: an extra identifier" do
  def guard_surfaces_contracts_copy
    real = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    Marshal.load(Marshal.dump(real))
  end

  # "A route, or a route and identifier pair, with no case fails the guard."
  it "R1 reports an invoice id added to the entry_api show path as an uncovered pair while the route stays covered" do
    contracts = guard_surfaces_contracts_copy
    contracts[:entry_api]["routes"]["show"]["path"] = "/v1/companies/{company_id}/invoices/{invoice_id}/entries/{entry_id}"

    report = TenantGuardSurfaces.uncovered(contracts: contracts, cases: TenantGuardCases::ALL)

    expect(report[:pairs]).to eq([%i[entry_api show invoice_id]])
    expect(report[:routes]).to be_empty
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: a replay outside the list for destroy" do
  def guard_surfaces_real_contracts
    TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
  end

  # "`uncovered` counts a replay toward its pairs only for that listed set."
  it "R8 does not count a replay toward the entry_api destroy key pair, which is outside the replay list" do
    kept = TenantGuardCases::ALL.reject do |kase|
      kase.contract == :entry_api && kase.route == :destroy && kase.covers.include?(:idempotency_key)
    end
    replay = TenantGuardCases::Case.new(
      contract: :entry_api, route: :destroy, mode: :replay, covers: [:idempotency_key], credential: :user_token,
      first: :owner, expected: { status: 404, reason: "not_found" }, headers: {}
    )

    report = TenantGuardSurfaces.uncovered(contracts: guard_surfaces_real_contracts, cases: kept + [replay])

    expect(report[:pairs]).to eq([%i[entry_api destroy idempotency_key]])
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: a replay outside the list for prepare" do
  def guard_surfaces_real_contracts
    TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
  end

  # "`uncovered` counts a replay toward its pairs only for that listed set."
  # The listed set holds the key cases only: "Replays: the key cases of create, update, bulk_move, prepare,
  # mark_billed and detach_entries, and the entry_snapshots key case."
  it "R8 does not count a prepare replay toward the prepare operation_id pair, though one body field carries both kinds" do
    kept = TenantGuardCases::ALL.reject do |kase|
      kase.contract == :reservations && kase.route == :prepare && kase.covers.include?(:operation_id)
    end
    replay = TenantGuardCases::Case.new(
      contract: :reservations, route: :prepare, mode: :replay, covers: %i[operation_id idempotency_key],
      credential: :service_token, first: :owner, expected: { status: 404, reason: "not_found" }, headers: {}
    )

    report = TenantGuardSurfaces.uncovered(contracts: guard_surfaces_real_contracts, cases: kept + [replay])

    expect(report[:pairs]).to eq([%i[reservations prepare operation_id]])
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: zero routes" do
  def guard_surfaces_contracts_copy
    real = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    Marshal.load(Marshal.dump(real))
  end

  # "Read the `routes:` map of every contract in `TimekeepingContract::CONTRACT_NAMES`, and fail when there are zero routes."
  it "R2 raises NoRoutesError when every contract's routes map is empty instead of reporting nothing uncovered" do
    contracts = guard_surfaces_contracts_copy
    contracts.each_value { |contract| contract["routes"] = {} if contract.key?("routes") }

    expect { TenantGuardSurfaces.uncovered(contracts: contracts, cases: TenantGuardCases::ALL) }
      .to raise_error(TenantGuardSurfaces::NoRoutesError)
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: an unrecognised route key" do
  def guard_surfaces_contracts_copy
    real = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    Marshal.load(Marshal.dump(real))
  end

  # "An unrecognised route field raises instead of being read as carrying no identifier"
  it "R3 raises UnknownFieldError for an unrecognised key on the handoff settle route rather than reading it as no identifier" do
    contracts = guard_surfaces_contracts_copy
    contracts[:handoff]["routes"]["settle"]["body_fields"] = ["invoice_ref"]

    expect { TenantGuardSurfaces.pairs(contracts) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /body_fields/)
  end
end

RSpec.describe "Timekeeping tenant guard surfaces: an unlisted field name" do
  def guard_surfaces_contracts_copy
    real = TimekeepingContract::CONTRACT_NAMES.index_with { |name| TimekeepingContract.load(name) }
    Marshal.load(Marshal.dump(real))
  end

  # "Every other name must be on an explicit non-identifier list: `company_id`, `project_id`, `user_id`, `agent_id`,
  # `generation`, `disposition`, `through`, `from`, `to`, `project_ids`, `schema_version`, and the entry_api
  # `entry_*_fields` body fields. An unlisted name raises."
  it "R11 raises UnknownFieldError for an unlisted request field on reservations commit and on entry_snapshots entry_fields" do
    commit_contracts = guard_surfaces_contracts_copy
    commit_contracts[:reservations]["routes"]["commit"]["request_fields"] << "tenant_ref"

    expect { TenantGuardSurfaces.pairs(commit_contracts) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)

    snapshot_contracts = guard_surfaces_contracts_copy
    snapshot_contracts[:entry_snapshots]["entry_fields"] << "tenant_ref"

    expect { TenantGuardSurfaces.pairs(snapshot_contracts) }
      .to raise_error(TenantGuardSurfaces::UnknownFieldError, /tenant_ref/)
  end
end

RSpec.describe "Timekeeping tenant guard cases: one foreign identifier per probe" do
  let(:requester_ids) do
    { company_id: 101, user_id: 111, project_id: 121, agent_id: 131, entry_ids: [141, 142],
      entry_versions: { 141 => 3, 142 => 4 }, invoice_id: 151, operation_id: "op-requester",
      idempotency_key: "key-requester", generation: 2 }
  end
  let(:owner_ids) do
    { company_id: 201, user_id: 211, project_id: 221, agent_id: 231, entry_ids: [241, 242],
      entry_versions: { 241 => 5, 242 => 6 }, invoice_id: 251, operation_id: "op-owner",
      idempotency_key: "key-owner", generation: 2 }
  end

  # Splits the path into segments so a swapped path parameter shows as one changed leaf.
  def guard_cases_request_leaves(request)
    flatten = lambda do |value, at|
      case value
      when Hash then value.flat_map { |key, nested| flatten.call(nested, at + [key]) }
      when Array then value.each_with_index.flat_map { |nested, index| flatten.call(nested, at + [index]) }
      else [[at, value]]
      end
    end
    flatten.call(request.merge(path: request.fetch(:path).split("/")), []).to_h
  end

  # "Each case swaps in exactly one foreign identifier and keeps the others valid for the requesting company."
  it "R5 every identifier probe differs from the requester's valid request in exactly one value, taken from the owner" do
    probes = TenantGuardCases::ALL.select { |kase| kase.mode == :probe && kase.covers != [:none] }
    owner_values = [*owner_ids[:entry_ids], owner_ids[:invoice_id], owner_ids[:operation_id], owner_ids[:idempotency_key]]
                   .map(&:to_s)
    expect(probes).not_to be_empty

    probes.each do |kase|
      valid = guard_cases_request_leaves(TenantGuardCases.valid_request(kase, ids: requester_ids))
      probe = guard_cases_request_leaves(TenantGuardCases.probe_request(kase, requester: requester_ids, owner: owner_ids))
      label = "#{kase.contract} #{kase.route} #{kase.covers.inspect}"

      expect(probe.keys).to match_array(valid.keys), label
      changed = probe.reject { |at, value| valid[at] == value }
      expect(changed.size).to eq(1), "#{label} changed #{changed.inspect}"
      expect(owner_values).to include(changed.values.first.to_s), label
    end
  end
end

RSpec.describe "Timekeeping tenant guard cases: bulk probe expected answer" do
  let(:owner_ids) do
    { company_id: 201, user_id: 211, project_id: 221, agent_id: 231, entry_ids: [241, 242],
      entry_versions: { 241 => 5, 242 => 6 }, invoice_id: 251, operation_id: "op-owner",
      idempotency_key: "key-owner", generation: 2 }
  end

  # "Bulk probes: 200, with that entry's `result` set to `not_found`."
  it "R9 a bulk_move entry probe expects not_found for the owner's swapped entry so a 200 that moved it cannot match" do
    kase = TenantGuardCases::ALL.find do |candidate|
      candidate.contract == :entry_api && candidate.route == :bulk_move && candidate.mode == :probe &&
        candidate.covers.include?(:entry_id)
    end

    answer = TenantGuardCases.expected_answer(kase, owner: owner_ids)

    expect(answer).to include(status: 200, results: [{ entry_id: 241, result: "not_found" }])
  end
end

RSpec.describe "Timekeeping tenant guard cases: baseline requests and remaining answers" do
  let(:guard_cases_requester_ids) do
    { company_id: 301, user_id: 311, project_id: 321, agent_id: 331, entry_ids: [341, 342],
      entry_versions: { 341 => 9, 342 => 10 }, invoice_id: 351, operation_id: "op-requester-3",
      idempotency_key: "key-requester-3", generation: 2 }
  end

  def guard_cases_find(contract, route, mode, covers)
    TenantGuardCases::ALL.find do |kase|
      kase.contract == contract && kase.route == route && kase.mode == mode && kase.covers == covers
    end
  end

  it "update and destroy entry requests send If-Match with the entry's version, and a delivered snapshot names its user" do
    %i[update destroy].each do |route|
      request = TenantGuardCases.valid_request(guard_cases_find(:entry_api, route, :probe, [:entry_id]),
                                               ids: guard_cases_requester_ids)

      expect(request.fetch(:path)).to eq("/v1/companies/301/entries/341"), route.to_s
      expect(request.fetch(:headers)).to include("If-Match" => "9"), route.to_s
    end

    deliver = TenantGuardCases.valid_request(guard_cases_find(:entry_snapshots, :deliver, :probe, [:entry_id]),
                                             ids: guard_cases_requester_ids)
    entry = deliver.fetch(:body).fetch("snapshots").first.fetch("entry")
    expect(entry).to include("id" => 341, "company_id" => 301, "user_id" => 311, "version" => 9)
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

  it "keeps the case table, every record and its nested values frozen" do
    expect(TenantGuardCases::ALL).to be_frozen
    TenantGuardCases::ALL.each do |kase|
      expect([kase, kase.covers, kase.expected, kase.headers]).to all(be_frozen)
      expect(kase.expected.fetch(:results, []) + kase.expected.fetch(:conflicts, [])).to all(be_frozen)
    end
  end
end

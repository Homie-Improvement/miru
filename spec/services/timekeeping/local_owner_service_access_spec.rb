# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LocalOwner::ServiceAccess do
  it "answers each caller kind by the access rule table before any write" do
    actor = Timekeeping::LocalOwner::Actor
    access = ->(who, company_id = 7) { described_class.call(actor: who, operation: :prepare, company_id:) }

    # "A nil actor answers `unauthorized`. A user actor, or a service without the operation, answers `forbidden`. A service bound to another company answers `not_found`."
    expect(access.call(nil)).to eq(:unauthorized)
    expect(access.call(actor.user(user_id: 1, role: "owner"))).to eq(:forbidden)
    expect(access.call(actor.service(name: "invoices", company_id: 7, operations: []))).to eq(:forbidden)
    expect(access.call(actor.service(name: "invoices", company_id: 8, operations: ["reservations.prepare"])))
      .to eq(:not_found)
    expect(access.call(actor.service(name: "invoices", company_id: 7, operations: ["reservations.prepare"])))
      .to eq(:ok)

    # An unbound service must never land in a company, whatever the company id's type.
    expect(access.call(actor.service(name: "invoices", company_id: nil, operations: ["reservations.prepare"])))
      .to eq(:not_found)
    expect(access.call(actor.service(name: "invoices", company_id: "", operations: ["reservations.prepare"])))
      .to eq(:not_found)
    expect(access.call(actor.service(name: "invoices", company_id: "7", operations: ["reservations.prepare"])))
      .to eq(:ok)
  end

  # "A grant for one route never admits another. A spec pins the map."
  it "pins the route to qualified operation map and admits each grant only for its own route" do
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

  # "An actor's operations count only where `TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS` also holds them."
  it "grants nothing for a background name outside the route grants or an unknown name" do
    import_only = Timekeeping::LocalOwner::Actor.service(name: "importer", company_id: 3, operations: ["entries.import"])
    unknown = Timekeeping::LocalOwner::Actor.service(name: "invoices", company_id: 3, operations: ["reservations.*", "admin"])
    %i[prepare commit abort].each do |route|
      expect(described_class.call(actor: import_only, operation: route, company_id: 3)).to eq(:forbidden)
      expect(described_class.call(actor: unknown, operation: route, company_id: 3)).to eq(:forbidden)
    end
  end
end

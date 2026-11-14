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
end

RSpec.describe Timekeeping::LocalOwner::ServiceAccess do
  it "admits a route only with that route's own qualified grant held in the background operations" do
    routes = described_class::ROUTE_OPERATIONS

    # "A grant for one route never admits another."
    routes.each do |route, _granted_name|
      routes.each do |other_route, other_name|
        service = Timekeeping::LocalOwner::Actor.service(name: "invoices", company_id: 3, operations: [other_name])
        expected = route == other_route ? :ok : :forbidden
        expect(described_class.call(actor: service, operation: route, company_id: 3)).to eq(expected),
          "#{other_name} grant on #{route}"
      end
    end

    # "An actor's operations count only where `TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS` also holds them."
    import_only = Timekeeping::LocalOwner::Actor.service(name: "importer", company_id: 3, operations: ["entries.import"])
    unknown = Timekeeping::LocalOwner::Actor.service(name: "invoices", company_id: 3, operations: ["reservations.*", "admin"])
    %i[prepare commit abort].each do |route|
      expect(described_class.call(actor: import_only, operation: route, company_id: 3)).to eq(:forbidden)
      expect(described_class.call(actor: unknown, operation: route, company_id: 3)).to eq(:forbidden)
    end
  end
end

RSpec.describe Timekeeping::LocalOwner::ServiceAccess do
  # "A spec pins the map."
  it "pins the route to qualified operation map" do
    expect(described_class::ROUTE_OPERATIONS).to eq(
      prepare: "reservations.prepare",
      commit: "reservations.commit",
      abort: "reservations.abort",
      mark_billed: "invoices.mark_billed",
      detach_entries: Timekeeping::ServiceToken::DETACH_ENTRIES
    )
    expect(Timekeeping::ServiceToken::DETACH_ENTRIES).to eq("agents.detach_entries")
  end
end

RSpec.describe Timekeeping::LocalOwner::ServiceAccess do
  it "no route's grant admits another route, a background name outside the route grants nothing, and an unbound service is never admitted" do
    actor_class = Timekeeping::LocalOwner::Actor
    routes = described_class::ROUTE_OPERATIONS

    # "A grant for one route never admits another."
    routes.each do |route, _name|
      routes.each do |granted_route, granted_name|
        next if granted_route == route

        actor = actor_class.service(name: "invoices", company_id: 7, operations: [granted_name])
        expect(described_class.call(actor:, operation: route, company_id: 7)).to eq(:forbidden)
      end
    end

    # "An actor's operations count only where `TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS` also holds them."
    import_only = actor_class.service(name: "invoices", company_id: 7, operations: ["entries.import"])
    expect(described_class.call(actor: import_only, operation: :prepare, company_id: 7)).to eq(:forbidden)

    # "A service bound to another company answers `not_found`."
    unbound = actor_class.service(name: "invoices", company_id: nil, operations: ["reservations.prepare"])
    expect(described_class.call(actor: unbound, operation: :prepare, company_id: 7)).to eq(:not_found)
    blank = actor_class.service(name: "invoices", company_id: "", operations: ["reservations.prepare"])
    expect(described_class.call(actor: blank, operation: :prepare, company_id: 7)).to eq(:not_found)
    other = actor_class.service(name: "invoices", company_id: 8, operations: ["reservations.prepare"])
    expect(described_class.call(actor: other, operation: :prepare, company_id: 7)).to eq(:not_found)

    same_as_string = actor_class.service(name: "invoices", company_id: "7", operations: ["reservations.prepare"])
    expect(described_class.call(actor: same_as_string, operation: :prepare, company_id: 7)).to eq(:ok)
  end
end

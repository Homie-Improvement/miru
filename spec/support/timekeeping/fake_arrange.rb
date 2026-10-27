# frozen_string_literal: true

require_relative "client"
require_relative "fake_reconciler"
require_relative "fake_relay"
require_relative "fake_timekeeping"

module TimekeepingContract
  # The setup object the shared contract examples call as timekeeping_arrange.
  # Each implementation provides one with these methods; this one seeds the
  # fakes. Ids are integers and credentials are generated test values.
  class FakeArrange
    def initialize(timekeeping:, relay:)
      @timekeeping = timekeeping
      @relay = relay
    end

    def company
      @timekeeping.add_company
    end

    def user(company:, role:)
      @timekeeping.add_user(company_id: company, role:)
    end

    def token_for(user)
      @timekeeping.issue_token(user)
    end

    # A credential for a background service. company nil means the service is
    # bound to no company, as the relay's Timekeeping identity is.
    def service_identity(company:, name:, operations:)
      @timekeeping.add_service(company_id: company, name:, operations:)
    end

    def project(company:)
      @timekeeping.add_project(company_id: company)
    end

    # An agent of the company that belongs to user.
    def agent(company:, user:)
      @timekeeping.add_agent(company_id: company, user_id: user)
    end

    def entry(company:, user:, project:, **attributes)
      @timekeeping.add_entry(company_id: company, user_id: user, project_id: project, **attributes).fetch("id")
    end

    # An entry that already holds a reservation, without calling the
    # reservation routes, so the entry examples run on their own.
    def reserved_entry(company:, invoice_id:, state: "committed", disposition: "active", **attributes)
      entry_id = entry(company:, user: user(company:, role: "employee"), project: project(company:), **attributes)
      @timekeeping.add_reservation(entry_id:, invoice_id:, state:, disposition:)
      entry_id
    end

    def current_generation
      @timekeeping.generation
    end

    # Moves ownership to a new generation on both sides.
    def set_generation(generation)
      @timekeeping.generation = generation
      @relay.generation = generation
    end

    def begin_handoff(previous_generation:, final_outbox_position:)
      @relay.begin_handoff(previous_generation:, final_outbox_position:)
    end

    delegate :flip_ownership, :projected_entry, to: :@relay
    # stored_entry returns the entry's stored fields as a string-keyed Hash.
    # The reservations group reads them here because a provider may run it
    # without the entry API.
    delegate :reservations_for, :stored_entry, to: :@timekeeping

    def published_snapshots
      @relay.next_batch
    end

    # How many outbox rows the provider holds, sent or not, so an example can
    # show a request wrote none.
    def outbox_size
      @timekeeping.outbox.size
    end

    def entry_locked(entry_id)
      @timekeeping.entry_locked?(entry_id)
    end
  end
end

# Wires the fakes into the lets the shared contract examples read. A spec can
# override one of the *_policies lets to break a single rule.
RSpec.shared_context "timekeeping contract fakes" do
  let(:timekeeping_fake_policies) { {} }
  let(:timekeeping_relay_policies) { {} }
  let(:timekeeping_reconciler_policies) { {} }
  let(:fake_timekeeping) { TimekeepingContract::FakeTimekeeping.new(policies: timekeeping_fake_policies) }
  let(:fake_relay) { TimekeepingContract::FakeRelay.new(source: fake_timekeeping, policies: timekeeping_relay_policies) }
  let(:timekeeping_client) { TimekeepingContract::FakeClient.new(timekeeping: fake_timekeeping, relay: fake_relay) }
  let(:timekeeping_arrange) { TimekeepingContract::FakeArrange.new(timekeeping: fake_timekeeping, relay: fake_relay) }
  let(:reconciler) { TimekeepingContract::FakeReconciler.new(policies: timekeeping_reconciler_policies) }
end

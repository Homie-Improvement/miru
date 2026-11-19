# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping seeded runtime hooks: after hook", committed_data: true do
  include InnerExampleThroughSuiteHooks

  it "the integrated_runtime after hook empties every table after a seeded example instead of reseeding" do
    steps = []
    runtime = instance_double(IntegratedRuntime)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return("1")
    allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test")
    allow(IntegratedRuntime).to receive(:refuse_if_running!)
    allow(IntegratedRuntime).to receive(:start).and_return(runtime)
    allow(runtime).to receive(:stop!) { steps << :stop }
    allow(TestDatabaseCleanup).to receive(:reset_seeded_committed!).and_wrap_original do |original, **kwargs|
      steps << :reseed
      original.call(**kwargs)
    end
    allow(TestDatabaseCleanup).to receive(:delete_all_committed!).and_wrap_original do |original|
      steps << :empty
      original.call
    end

    seen_companies = nil
    result = run_inner_example_through_suite_hooks(
      { integrated_runtime: true, two_tenant_seed: true, committed_data: true },
      { owner_state: "timekeeping" }
    ) { seen_companies = Company.count }

    expect(result.status).to eq(:passed)
    expect(seen_companies).to be >= 2

    # "The after hook still empties every table."
    after_stop = steps.drop(steps.index(:stop) + 1)
    expect(after_stop).to include(:empty)
    expect(after_stop).not_to include(:reseed)
    expect(Company.count).to eq(0)
    expect(TimekeepingOwnership.count).to eq(1)
  end
end

RSpec.describe "Timekeeping seeded runtime hooks: unknown owner state" do
  # "An unknown owner_state name raises an ArgumentError naming the valid states"
  it "for_example rejects an unknown owner_state name instead of falling back to the selected state" do
    # A valid process-wide state must not hide a mistyped example state.
    stub_const("TimekeepingOwnerState::SELECTED", "legacy")

    %w[bogus Timekeeping].each do |name|
      expect { TimekeepingOwnerState.for_example(owner_state: name) }
        .to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/m)
    end
  end
end

RSpec.describe "Timekeeping seeded runtime hooks: repeated seeded clean", :two_tenant_seed, committed_data: true do
  before { allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test") }

  # "An example tagged :integrated_runtime, :two_tenant_seed and committed_data: true starts the runtime with
  # fork_and_leaf and copper_kettle and their entries present in the monolith"
  # The committed_data hook has already loaded the seed, so this is the second and third load in a row.
  it "a seeded clean run twice over an already loaded seed leaves each seeded company once with its entries and the timekeeping state" do
    2.times { IntegratedRuntime.clean_monolith!(seeded: true, owner_state: "timekeeping", env: {}) }

    expect(Company.where(name: "Fork & Leaf Salads").count).to eq(1)
    expect(Company.where(name: "Copper Kettle Bakery").count).to eq(1)
    [fork_and_leaf, copper_kettle].each do |company|
      entries = TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })
      expect(entries.exists?).to be(true)
    end
    expect(TimekeepingOwnership.count).to eq(1)
    expect_owner_state!("timekeeping")
  end
end

RSpec.describe "Timekeeping seeded runtime hooks: unseeded clean after a seed", :two_tenant_seed, committed_data: true do
  before { allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test") }

  # "Examples without the seed tag are still emptied as today, and spec/db/committed_data_mode_spec.rb and
  # spec/meta/timekeeping_integration_tags_spec.rb stay green"
  # The seed is present when the clean runs, so a clean that ignored seeded: false would leave it behind.
  it "an unseeded clean after the seed was loaded still deletes the seed and leaves one legacy ownership row" do
    expect(Company.where(name: "Fork & Leaf Salads").exists?).to be(true)

    IntegratedRuntime.clean_monolith!(seeded: false, owner_state: nil)

    expect(Company.count).to eq(0)
    expect(TimesheetEntry.count).to eq(0)
    expect(User.count).to eq(0)
    expect(TimekeepingOwnership.count).to eq(1)
    expect_owner_state!("legacy")
  end
end

RSpec.describe "Timekeeping seeded runtime hooks: example state over selected state" do
  include InnerExampleThroughSuiteHooks

  # "An example's owner_state metadata (legacy, timekeeping or rollback) sets the ownership row and the runtime's
  # owner state for that example, and is checked by expect_owner_state!"
  # "An example tagged :integrated_runtime, :two_tenant_seed and committed_data: true starts the runtime with
  # fork_and_leaf and copper_kettle and their entries present in the monolith"
  # The process-wide state is a different valid state, so a hook that still read it would boot the wrong owner.
  it "a seeded runtime example whose owner_state differs from the selected state boots with its own state and keeps the seed" do
    stub_const("TimekeepingOwnerState::SELECTED", "timekeeping")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return("1")
    allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test")
    allow(IntegratedRuntime).to receive(:refuse_if_running!)
    runtime = instance_double(IntegratedRuntime)
    allow(runtime).to receive(:stop!)
    start_owner_states = []
    allow(IntegratedRuntime).to receive(:start) do |**options|
      start_owner_states << options[:owner_state]
      runtime
    end

    seen = {}
    result = run_inner_example_through_suite_hooks(
      { integrated_runtime: true, two_tenant_seed: true, committed_data: true }, { owner_state: "rollback" }
    ) do
      seen[:companies] = Company.where(name: ["Fork & Leaf Salads", "Copper Kettle Bakery"]).count
      seen[:entries] = TimesheetEntry.count.positive?
      ownership = TimekeepingOwnership.current
      seen[:ownership] = [ownership.owner, ownership.monolith_store, ownership.generation]
    end

    expect(result.exception).to be_nil
    expect(start_owner_states).to eq(["rollback"])
    expect(seen).to eq(companies: 2, entries: true, ownership: ["monolith", "prepared", 3])
  ensure
    TimekeepingOwnership.ensure_initial!
  end
end

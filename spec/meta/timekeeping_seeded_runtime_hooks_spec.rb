# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Timekeeping seeded runtime hooks" do
  seeded_company_names = ["Fork & Leaf Salads", "Copper Kettle Bakery"]

  describe "TimekeepingOwnerState.for_example" do
    # "`for_example` prefers `metadata[:owner_state]` and falls back to `SELECTED`."
    it "prefers the example's owner_state over SELECTED" do
      stub_const("TimekeepingOwnerState::SELECTED", "legacy")

      expect(TimekeepingOwnerState.for_example({ owner_state: "timekeeping" })).to eq("timekeeping")
      expect(TimekeepingOwnerState.for_example({ owner_state: "rollback" })).to eq("rollback")
    end

    it "falls back to SELECTED when the example names no owner_state" do
      stub_const("TimekeepingOwnerState::SELECTED", "legacy")
      expect(TimekeepingOwnerState.for_example({})).to eq("legacy")

      stub_const("TimekeepingOwnerState::SELECTED", "rollback")
      expect(TimekeepingOwnerState.for_example({})).to eq("rollback")
      expect(TimekeepingOwnerState.for_example({ owner_state: nil })).to eq("rollback")
    end

    # An unset run with no metadata must leave the ownership row untouched, so nil is not treated as an
    # unknown name.
    it "returns nil when neither the example nor the run selects a state" do
      stub_const("TimekeepingOwnerState::SELECTED", nil)

      expect(TimekeepingOwnerState.for_example({})).to be_nil
      expect(TimekeepingOwnerState.for_example({ owner_state: "timekeeping" })).to eq("timekeeping")
    end

    # "An unknown owner_state name raises an ArgumentError naming the valid states"
    it "raises an ArgumentError naming the valid states for an unknown owner_state name" do
      expect { TimekeepingOwnerState.for_example({ owner_state: "bogus" }) }
        .to raise_error(ArgumentError, /"bogus".*legacy.*timekeeping.*rollback/m)
    end

    # A selected run state must not hide a mistyped example state by falling back to it.
    it "rejects an unknown owner_state name even when a valid state is selected for the run" do
      stub_const("TimekeepingOwnerState::SELECTED", "legacy")

      ["bogus", "Timekeeping", "timekeeping "].each do |name|
        expect { TimekeepingOwnerState.for_example({ owner_state: name }) }
          .to raise_error(ArgumentError, /#{Regexp.escape(name.inspect)}.*legacy.*timekeeping.*rollback/m)
      end
    end
  end

  describe "IntegratedRuntime.clean_monolith!", committed_data: true do
    # The guard accepts only names ending in _test; parallel workers use numbered databases.
    before { allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test") }

    after { TimekeepingOwnership.ensure_initial! }

    # "`clean_monolith!(seeded: true, owner_state: "timekeeping")` leaves both seeded companies with their
    #  entries, and the ownership row in the timekeeping state (`expect_owner_state!("timekeeping")`)."
    it "with seeded true loads both seeded companies with their entries and puts the row in the timekeeping state" do
      # This example has no seed tag, so the committed_data hook left the tables empty.
      expect(Company.count).to eq(0)

      # An env without TIMEKEEPING_DATABASE_URL, so no Timekeeping database is needed.
      IntegratedRuntime.clean_monolith!(seeded: true, owner_state: "timekeeping", env: {})

      seeded_company_names.each do |name|
        company = Company.find_by!(name:)
        entries = TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })
        expect(entries.count).to be > 0
      end
      expect(TimekeepingOwnership.count).to eq(1)
      expect_owner_state!("timekeeping")
    end

    # "`clean_monolith!(seeded: false)` still empties every table."
    # The seed is loaded first, so a clean that ignored seeded: false would leave it behind.
    it "with seeded false empties every table and leaves one legacy ownership row" do
      TestDatabaseCleanup.reset_seeded_committed!(as_of: TestDatabaseCleanup.seed_as_of, state: nil, env: {})
      expect(Company.count).to be > 0

      IntegratedRuntime.clean_monolith!(seeded: false, owner_state: nil)

      expect(occupied_committed_tables).to eq([])
      # delete_all_committed! puts the ownership row back after deleting it.
      expect(TimekeepingOwnership.count).to eq(1)
      expect_owner_state!("legacy")
    end

    it "with seeded false and the default owner state empties every table except the restored ownership row" do
      TestDatabaseCleanup.reset_seeded_committed!(as_of: TestDatabaseCleanup.seed_as_of, state: nil, env: {})
      expect(Company.count).to be > 0

      IntegratedRuntime.clean_monolith!(seeded: false)

      expect(occupied_committed_tables).to eq([])
      expect(TimekeepingOwnership.count).to eq(1)
    end

    describe "over an already loaded seed", :two_tenant_seed do
      # The committed_data hook has already loaded the seed, so this is the second and third load in a row.
      it "a seeded clean run twice leaves each seeded company once with its entries and the timekeeping state" do
        2.times { IntegratedRuntime.clean_monolith!(seeded: true, owner_state: "timekeeping", env: {}) }

        seeded_company_names.each { |name| expect(Company.where(name:).count).to eq(1) }
        [fork_and_leaf, copper_kettle].each do |company|
          entries = TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })
          expect(entries.exists?).to be(true)
        end
        expect(TimekeepingOwnership.count).to eq(1)
        expect_owner_state!("timekeeping")
      end
    end

    def occupied_committed_tables
      connection = ActiveRecord::Base.connection
      checked = connection.tables - TestDatabaseCleanup::KEPT_TABLES - [TimekeepingOwnership.table_name]
      checked.select do |table|
        connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i.positive?
      end
    end
  end

  describe "the suite hooks", committed_data: true do
    include InnerExampleThroughSuiteHooks

    after { TimekeepingOwnership.ensure_initial! }

    # "An example tagged :integrated_runtime, :two_tenant_seed and committed_data: true starts the runtime with
    #  fork_and_leaf and copper_kettle and their entries present in the monolith"
    # "An example's owner_state metadata (legacy, timekeeping or rollback) sets the ownership row and the
    #  runtime's owner state for that example, and is checked by expect_owner_state!"
    # The run selects a different valid state, so a hook that still read it would boot the wrong owner.
    it "start a seeded integrated_runtime example on both seeded companies in the owner state its metadata names" do
      stub_const("TimekeepingOwnerState::SELECTED", "timekeeping")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TIMEKEEPING_LIVE").and_return("1")
      allow(IntegratedRuntime).to receive(:monolith_database_name).and_return("miru_web_test")
      allow(IntegratedRuntime).to receive(:refuse_if_running!)
      runtime = instance_double(IntegratedRuntime, stop!: nil)
      companies_at_start = []
      allow(IntegratedRuntime).to receive(:start).with(hash_including(owner_state: "rollback")) do
        companies_at_start << seeded_company_names.map { |name| Company.where(name:).count }
        runtime
      end
      allow(TimekeepingDatabaseReset).to receive(:reset!).and_call_original
      seen = {}

      result = run_inner_example_through_suite_hooks(
        { integrated_runtime: true, two_tenant_seed: true, committed_data: true }, { owner_state: "rollback" }
      ) do
        seen[:entries] = [fork_and_leaf, copper_kettle].map do |company|
          TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id }).count
        end
        expect_owner_state!("rollback")
      end

      expect(result.exception).to be_nil
      expect(companies_at_start).to eq([[1, 1]])
      expect(seen[:entries]).to all(be > 0)
      expect(IntegratedRuntime).to have_received(:start).with(hash_including(owner_state: "rollback")).once
      # The Timekeeping admission row is reset in the example's state by the runtime hook's seeded clean, which
      # alone passes ENV.to_h; the owner-state hook re-applies only the monolith row, so it cannot hide this.
      expect(TimekeepingDatabaseReset).to have_received(:reset!).with("rollback", env: ENV.to_h).once
      expect(TimekeepingDatabaseReset).not_to have_received(:reset!).with("timekeeping", env: anything)
      expect(runtime).to have_received(:stop!).once
    end

    # "The after hook still empties every table."
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
        { integrated_runtime: true, two_tenant_seed: true, committed_data: true }, { owner_state: "timekeeping" }
      ) { seen_companies = Company.count }

      expect(result.status).to eq(:passed)
      expect(seen_companies).to be >= 2
      after_stop = steps.drop(steps.index(:stop) + 1)
      expect(after_stop).to include(:empty)
      expect(after_stop).not_to include(:reseed)
      expect(Company.count).to eq(0)
      expect(TimekeepingOwnership.count).to eq(1)
    end

    # "An example's owner_state metadata (legacy, timekeeping or rollback) sets the ownership row and the
    #  runtime's owner state for that example, and is checked by expect_owner_state!"
    it "hold a seeded committed example without the runtime tag in the owner state its metadata names" do
      stub_const("TimekeepingOwnerState::SELECTED", nil)
      allow(TimekeepingDatabaseReset).to receive(:reset!).and_call_original
      seen = {}

      result = run_inner_example_through_suite_hooks(
        { committed_data: true, two_tenant_seed: true }, { owner_state: "timekeeping" }
      ) do
        seen[:companies] = Company.where(name: seeded_company_names).count
        expect_owner_state!("timekeeping")
      end

      expect(result.exception).to be_nil
      expect(seen[:companies]).to eq(2)
      # The owner-state hook re-applies the monolith row afterwards, so only this shows the committed_data hook
      # reset the Timekeeping admission row in the example's state.
      expect(TimekeepingDatabaseReset).to have_received(:reset!).with("timekeeping", env: anything).once
    end

    # An unseeded committed example's cleanup leaves the legacy row, so only the owner-state hook can put the
    # row in the state the metadata names.
    it "hold an unseeded committed example in the owner state its metadata names" do
      stub_const("TimekeepingOwnerState::SELECTED", nil)

      result = run_inner_example_through_suite_hooks({ committed_data: true }, { owner_state: "rollback" }) do
        expect_owner_state!("rollback")
      end

      expect(result.exception).to be_nil
    end
  end
end

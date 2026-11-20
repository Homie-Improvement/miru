# frozen_string_literal: true

require "rails_helper"

RSpec.describe "arrange_owned_entries with a repeated id in one call", committed_data: true do
  it "a repeated id inside one timekeeping call raises ArgumentError before the store or the projection is touched" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    calls = []
    store = Object.new
    store.define_singleton_method(:fence_admission) { calls << :fence_admission }
    store.define_singleton_method(:load_checkpoint) { |checkpoint| calls << :load_checkpoint; checkpoint }
    store.define_singleton_method(:advance_entry_id_sequence) { |above:| calls << :advance_entry_id_sequence; above + 1 }
    store.define_singleton_method(:admit) { |generation:| calls << :admit }

    projection_count = TimesheetEntry.unscoped.count
    rows = [
      { company:, user:, project:, id: 900_701 },
      { company:, user:, project:, id: "900701" }
    ]

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    expect { arrange_owned_entries(rows, state: "timekeeping", timekeeping_store: store) }.to raise_error(ArgumentError)
    expect(calls).to be_empty
    expect(TimesheetEntry.unscoped.count).to eq(projection_count)
  end
end

RSpec.describe "arrange_owned_entries with an id repeated across calls", committed_data: true do
  it "an id repeating one arranged by an earlier rollback call raises ArgumentError and adds no prepared, reservation or projection row" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    first_id = arrange_owned_entries([{ company:, user:, project: }], state: "rollback").first

    reservation_count = -> { ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM reservations").to_i }
    counts_before = [TimesheetEntry.unscoped.count, Timekeeping::LocalEntry.count, reservation_count.call]

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    expect do
      arrange_owned_entries(
        [{ company:, user:, project:, id: first_id + 1_000 }, { company:, user:, project:, id: first_id, locked: true }],
        state: "rollback"
      )
    end.to raise_error(ArgumentError)

    expect([TimesheetEntry.unscoped.count, Timekeeping::LocalEntry.count, reservation_count.call]).to eq(counts_before)
  end
end

RSpec.describe "arrange_owned_entries when the Timekeeping load fails", committed_data: true do
  it "a failed load still admits at generation 2, raises the original error, writes no projection, and the same batch can then be arranged again" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    load_failure = Class.new(StandardError)
    calls = []
    failing_load = true
    store = Object.new
    store.define_singleton_method(:fence_admission) { calls << [:fence_admission] }
    store.define_singleton_method(:load_checkpoint) do |checkpoint|
      calls << [:load_checkpoint]
      raise load_failure, "load refused" if failing_load

      checkpoint
    end
    store.define_singleton_method(:advance_entry_id_sequence) { |above:| calls << [:advance_entry_id_sequence, above]; above + 1 }
    store.define_singleton_method(:admit) { |generation:| calls << [:admit, generation] }

    rows = [{ company:, user:, project:, id: 900_811, note: "first try" }]

    # "with an injected store whose `load_checkpoint` raises, `admit(generation: 2)` is still called and the original error propagates."
    expect { arrange_owned_entries(rows, state: "timekeeping", timekeeping_store: store) }.to raise_error(load_failure)
    expect(calls).to eq([[:fence_admission], [:load_checkpoint], [:admit, 2]])
    expect(TimesheetEntry.unscoped.find_by(id: 900_811)).to be_nil

    # The failed call recorded nothing, so sending the same batch again is not a repeated id.
    failing_load = false
    calls.clear
    expect(arrange_owned_entries(rows, state: "timekeeping", timekeeping_store: store)).to eq([900_811])
    expect(calls).to eq([[:fence_admission], [:load_checkpoint], [:advance_entry_id_sequence, 900_811], [:admit, 2]])
    expect(TimesheetEntry.unscoped.where(id: 900_811).count).to eq(1)
  end
end

RSpec.describe "arrange_owned_entries when the load and the admit both fail", committed_data: true do
  it "when both the load and the admit raise, the load error is the one that propagates" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    load_failure = Class.new(StandardError)
    admit_failure = Class.new(StandardError)
    admitted = []
    store = Object.new
    store.define_singleton_method(:fence_admission) { nil }
    store.define_singleton_method(:load_checkpoint) { |_checkpoint| raise load_failure, "load refused" }
    store.define_singleton_method(:advance_entry_id_sequence) { |above:| above + 1 }
    store.define_singleton_method(:admit) do |generation:|
      admitted << generation
      raise admit_failure, "admit refused"
    end

    # "If `admit` raises while another error propagates, the original error wins."
    expect do
      arrange_owned_entries([{ company:, user:, project:, id: 900_921 }], state: "timekeeping", timekeeping_store: store)
    end.to raise_error(load_failure)
    expect(admitted).to eq([2])
  end
end

RSpec.describe "arrange_owned_entries in the rollback state", committed_data: true do
  it "rollback entries are read through EntryLookup.local_entry with locked from a written reservation and each has a projection row with the same id" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id: "owned-entries-spec")

    locked_id, open_id = arrange_owned_entries(
      [{ company:, user:, project:, locked: true }, { company: company.id, user: user.id, project: project.id }],
      state: "rollback"
    )

    # "a locked rollback fixture reads locked true through `EntryLookup.local_entry` because a reservation row is written"
    expect(Timekeeping::EntryLookup.local_entry(context:, entry_id: locked_id).entry.locked).to be(true)
    expect(Timekeeping::EntryLookup.local_entry(context:, entry_id: open_id).entry.locked).to be(false)
    reserved = ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_array(["SELECT COUNT(*) FROM reservations WHERE entry_id = ?", locked_id])
    ).to_i
    expect(reserved).to eq(1)

    # "In the rollback state each arranged entry also has a projection `timesheet_entries` row with the same id"
    expect(TimesheetEntry.unscoped.where(id: [locked_id, open_id]).count).to eq(2)
  end
end

RSpec.describe "arrange_owned_entries in the legacy state", committed_data: true do
  it "legacy entries land only in timesheet_entries, in input order, with no prepared or reservation row" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    reservation_count = -> { ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM reservations").to_i }
    prepared_before = Timekeeping::LocalEntry.count
    reservations_before = reservation_count.call

    ids = arrange_owned_entries(
      [{ company:, user:, project:, id: 900_602, note: "second" }, { company:, user:, project:, note: "first" }],
      state: "legacy"
    )

    # "in the legacy state, rows land only in `timesheet_entries`."
    expect(ids.first).to eq(900_602)
    expect(TimesheetEntry.unscoped.where(id: ids).order(:id).pluck(:id, :note).to_h).to eq(ids.zip(%w[second first]).to_h)
    expect(Timekeeping::LocalEntry.count).to eq(prepared_before)
    expect(reservation_count.call).to eq(reservations_before)
  end
end

RSpec.describe "owned_entry reading the owning store", committed_data: true do
  it "owned_entry in the rollback state returns the prepared entry's note after the projection note is changed" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    rollback_id = arrange_owned_entries([{ company:, user:, project:, note: "owner note" }], state: "rollback").first
    TimesheetEntry.unscoped.find(rollback_id).update_columns(note: "projection note")

    # "`owned_entry(id, state: "rollback")` returns the owning `Timekeeping::LocalEntry` note, not the projection's"
    expect(owned_entry(rollback_id, state: "rollback").fetch("note")).to eq("owner note")

    legacy_id = arrange_owned_entries([{ company:, user:, project:, note: "legacy note" }], state: "legacy").first
    TimesheetEntry.unscoped.find(legacy_id).update_columns(note: "edited legacy note")

    # "`owned_entry(id, state: "legacy")` returns the `timesheet_entries` row's fields."
    expect(owned_entry(legacy_id, state: "legacy").fetch("note")).to eq("edited legacy note")
  end
end

RSpec.describe "arrange_owned_entries", :without_transaction, committed_data: true do
  it "arrange_owned_entries in the rollback state stores each row under its own company, so EntryLookup.local_entry finds it only for that company" do
    tenants = Array.new(2) do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user:)
      user.add_role(:admin, company)
      project = create(:project, billable: true, client: create(:client, company:))
      context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user",
                                              request_id: "owned-entries-tenant-spec")
      { company:, user:, project:, context: }
    end
    first, second = tenants

    # One batch with rows of two companies: each row must keep its own company,
    # not the batch's first company.
    first_id, second_id = arrange_owned_entries(
      tenants.map { |tenant| tenant.slice(:company, :user, :project) },
      state: "rollback"
    )

    expect(Timekeeping::EntryLookup.local_entry(context: first[:context], entry_id: first_id).entry.id).to eq(first_id)
    expect(Timekeeping::EntryLookup.local_entry(context: second[:context], entry_id: second_id).entry.id).to eq(second_id)
    expect(Timekeeping::LocalEntry.find(second_id).company_id).to eq(second[:company].id)
    expect(TimesheetEntry.unscoped.find(second_id).company_id).to eq(second[:company].id)

    expect { Timekeeping::EntryLookup.local_entry(context: first[:context], entry_id: second_id) }
      .to raise_error(ActiveRecord::RecordNotFound)
    expect { Timekeeping::EntryLookup.local_entry(context: second[:context], entry_id: first_id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end

RSpec.describe "arrange_owned_entries admission restore after a failed load", committed_data: true do
  it "arrange_owned_entries in the timekeeping state admits generation 2 after load_checkpoint raises and re-raises the load error" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    load_failure = Class.new(StandardError)
    store = Class.new do
      attr_reader :calls

      def initialize(load_error)
        @calls = []
        @load_error = load_error
      end

      def fence_admission
        @calls << [:fence_admission]
        nil
      end

      def load_checkpoint(_checkpoint)
        @calls << [:load_checkpoint]
        raise @load_error
      end

      def advance_entry_id_sequence(above:)
        @calls << [:advance_entry_id_sequence, { above: }]
        Integer(above) + 1
      end

      def admit(generation:)
        @calls << [:admit, { generation: }]
        nil
      end
    end.new(load_failure.new("load refused"))
    projections_before = TimesheetEntry.unscoped.count

    # "admission is restored at the state's admission generation even when `load_checkpoint` raises, and the original error propagates"
    expect do
      arrange_owned_entries([{ company:, user:, project:, note: "admission restore" }], state: "timekeeping",
                                                                                         timekeeping_store: store)
    end.to raise_error(load_failure, "load refused")

    expect(store.calls.map(&:first)).to eq(%i[fence_admission load_checkpoint admit])
    expect(store.calls.last).to eq([:admit, { generation: 2 }])
    expect(TimesheetEntry.unscoped.count).to eq(projections_before)
  end
end

RSpec.describe "arrange_owned_entries when admit also fails", committed_data: true do
  it "arrange_owned_entries keeps the load error when admit also raises in the timekeeping state" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    load_failure = Class.new(StandardError)
    admit_failure = Class.new(StandardError)
    store = Class.new do
      attr_reader :calls

      def initialize(load_error, admit_error)
        @calls = []
        @load_error = load_error
        @admit_error = admit_error
      end

      def fence_admission
        @calls << [:fence_admission]
        nil
      end

      def load_checkpoint(_checkpoint)
        @calls << [:load_checkpoint]
        raise @load_error
      end

      def advance_entry_id_sequence(above:)
        @calls << [:advance_entry_id_sequence, { above: }]
        Integer(above) + 1
      end

      def admit(generation:)
        @calls << [:admit, { generation: }]
        raise @admit_error
      end
    end.new(load_failure.new("load refused"), admit_failure.new("admit refused"))

    # "If `admit` raises while another error propagates, the original error wins."
    expect do
      arrange_owned_entries([{ company:, user:, project: }], state: "timekeeping", timekeeping_store: store)
    end.to raise_error(load_failure, "load refused")
    expect(store.calls.last).to eq([:admit, { generation: 2 }])
  end
end

RSpec.describe "arrange_owned_entries timekeeping union across calls", committed_data: true do
  it "arrange_owned_entries loads the union of both batches and advances above the highest union id in the timekeeping state" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    store = Class.new do
      attr_reader :calls, :loaded_ids

      def initialize
        @calls = []
        @loaded_ids = []
      end

      def fence_admission
        @calls << [:fence_admission]
        nil
      end

      def load_checkpoint(checkpoint)
        @calls << [:load_checkpoint]
        @loaded_ids << checkpoint.rows.fetch("entries").pluck("id").sort
        checkpoint
      end

      def advance_entry_id_sequence(above:)
        @calls << [:advance_entry_id_sequence, { above: }]
        Integer(above) + 1
      end

      def admit(generation:)
        @calls << [:admit, { generation: }]
        nil
      end
    end.new

    first_ids = arrange_owned_entries([{ company:, user:, project:, note: "first batch" }],
                                      state: "timekeeping", timekeeping_store: store)
    second_ids = arrange_owned_entries([{ company:, user:, project:, note: "second batch" }],
                                       state: "timekeeping", timekeeping_store: store)

    # "keep the rows arranged so far in the example and load their union, because `load_checkpoint` replaces whole tables; a second call must not drop the first batch."
    expect(store.loaded_ids.last).to eq((first_ids + second_ids).sort)
    # "`advance_entry_id_sequence(above:)` gets the highest id across the whole union."
    advances = store.calls.select { |name, _| name == :advance_entry_id_sequence }
    expect(advances.last).to eq([:advance_entry_id_sequence, { above: (first_ids + second_ids).max }])
    # "call `fence_admission`, then `load_checkpoint`, then `advance_entry_id_sequence(above:)` the highest loaded id, then `admit(generation:)`"
    expect(store.calls.map(&:first).last(4)).to eq(%i[fence_admission load_checkpoint advance_entry_id_sequence admit])
    # "Then write the projection rows (monolith `timesheet_entries`)."
    expect(TimesheetEntry.unscoped.where(id: first_ids + second_ids).count).to eq(2)
  end
end

RSpec.describe "arrange_owned_entries repeated id within one call", committed_data: true do
  it "arrange_owned_entries raises ArgumentError for a repeated id within one call and calls no store" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    store = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def fence_admission = @calls << :fence_admission
      def load_checkpoint(checkpoint) = (@calls << :load_checkpoint) && checkpoint
      def advance_entry_id_sequence(above:) = (@calls << :advance_entry_id_sequence) && (Integer(above) + 1)
      def admit(generation:) = @calls << [:admit, generation]
    end.new
    repeated_id = ActiveRecord::Base.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i
    counts = lambda do
      [TimesheetEntry.unscoped.count, Timekeeping::LocalEntry.count,
       ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM reservations").to_i]
    end
    before_counts = counts.call

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    expect do
      arrange_owned_entries([{ company:, user:, project:, id: repeated_id },
                             { company:, user:, project:, id: repeated_id.to_s }],
                            state: "timekeeping", timekeeping_store: store)
    end.to raise_error(ArgumentError)

    expect(store.calls).to be_empty
    expect(counts.call).to eq(before_counts)
  end
end

RSpec.describe "arrange_owned_entries repeated id across calls", committed_data: true, owner_state: "rollback" do
  it "arrange_owned_entries raises ArgumentError for an id arranged by an earlier call and writes none of the second batch" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    first_id = arrange_owned_entries([{ company:, user:, project:, note: "first" }], state: "rollback").first
    fresh_id = ActiveRecord::Base.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    expect do
      arrange_owned_entries([{ company:, user:, project:, id: fresh_id, note: "fresh" },
                             { company:, user:, project:, id: first_id, note: "repeat" }], state: "rollback")
    end.to raise_error(ArgumentError)

    expect(Timekeeping::LocalEntry.where(id: fresh_id)).not_to exist
    expect(TimesheetEntry.unscoped.where(id: fresh_id)).not_to exist
    expect(Timekeeping::LocalEntry.where(id: first_id).count).to eq(1)
    expect(TimesheetEntry.unscoped.where(id: first_id).count).to eq(1)
  end
end

RSpec.describe "arrange_owned_entries in the rollback state", committed_data: true, owner_state: "rollback" do
  it "arrange_owned_entries in the rollback state is read by EntryLookup.local_entry with locked from reservations and a same-id projection" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id: "owned-entries-spec")

    locked_id, open_id = arrange_owned_entries(
      [{ company:, user:, project:, note: "locked row", locked: true },
       { company:, user:, project:, note: "open row" }], state: "rollback"
    )

    # "in the rollback state the same entry is read through `EntryLookup.local_entry`"
    locked_entry = Timekeeping::EntryLookup.local_entry(context:, entry_id: locked_id).entry
    open_entry = Timekeeping::EntryLookup.local_entry(context:, entry_id: open_id).entry
    expect(locked_entry.id).to eq(locked_id)
    expect(open_entry.id).to eq(open_id)
    # "a locked rollback fixture reads locked true through `EntryLookup.local_entry` because a reservation row is written"
    expect(locked_entry.locked).to be(true)
    # "A `locked: true` row reads locked true; one without a reservation reads false."
    expect(open_entry.locked).to be(false)
    reservation_entry_ids = ActiveRecord::Base.connection.select_values("SELECT entry_id FROM reservations").map(&:to_i)
    expect(reservation_entry_ids).to eq([locked_id])
    # "In the rollback state each arranged entry also has a projection `timesheet_entries` row with the same id"
    expect(TimesheetEntry.unscoped.where(id: [locked_id, open_id]).pluck(:id)).to contain_exactly(locked_id, open_id)
  end
end

RSpec.describe "arrange_owned_entries in the legacy state", committed_data: true, owner_state: "legacy" do
  it "arrange_owned_entries in the legacy state writes only timesheet_entries and returns ids in input order" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    explicit_id = ActiveRecord::Base.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i
    local_before = Timekeeping::LocalEntry.count
    reservations_before = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM reservations").to_i

    ids = arrange_owned_entries(
      [{ company:, user:, project:, note: "first" },
       { company: company.id, user: user.id, project: project.id, id: explicit_id, note: "second" },
       { company:, user:, project:, note: "third" }], state: "legacy"
    )

    # "it returns the ids in input order"
    expect(ids.size).to eq(3)
    expect(ids[1]).to eq(explicit_id)
    expect(ids.uniq.size).to eq(3)
    # "in the legacy state, rows land only in `timesheet_entries`."
    expect(TimesheetEntry.unscoped.where(id: ids).order(:id).pluck(:id, :note).to_h)
      .to eq(ids.zip(%w[first second third]).to_h)
    expect(Timekeeping::LocalEntry.count).to eq(local_before)
    expect(ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM reservations").to_i).to eq(reservations_before)
  end
end

RSpec.describe "arrange_owned_entries without a live adapter", committed_data: true do
  it "arrange_owned_entries raises a clear error in the timekeeping state with no adapter and no injected store and writes nothing" do
    skip "The live adapter is running, so this example cannot show the no-adapter error" if TimekeepingRegressionAdapter.current
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    projections_before = TimesheetEntry.unscoped.count

    # "With no adapter running, the timekeeping writer raises a clear error."
    expect do
      arrange_owned_entries([{ company:, user:, project: }], state: "timekeeping")
    end.to raise_error(StandardError, /adapter/i)
    expect(TimesheetEntry.unscoped.count).to eq(projections_before)
  end
end

RSpec.describe "arrange_owned_entries with an unknown state", committed_data: true do
  it "arrange_owned_entries raises ArgumentError for an unknown owner state and writes nothing" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    projections_before = TimesheetEntry.unscoped.count
    local_before = Timekeeping::LocalEntry.count

    expect do
      arrange_owned_entries([{ company:, user:, project: }], state: "Legacy")
    end.to raise_error(ArgumentError)
    expect(TimesheetEntry.unscoped.count).to eq(projections_before)
    expect(Timekeeping::LocalEntry.count).to eq(local_before)
  end
end

RSpec.describe "owned_entry in the rollback state", committed_data: true, owner_state: "rollback" do
  it "owned_entry in the rollback state returns the LocalEntry note, not the changed projection note" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    entry_id = arrange_owned_entries([{ company:, user:, project:, note: "owner note", locked: true }],
                                     state: "rollback").first
    TimesheetEntry.unscoped.find(entry_id).update_columns(note: "projection note", locked: false)

    # "`owned_entry(id, state: "rollback")` returns the owning `Timekeeping::LocalEntry` note, not the projection's"
    fields = owned_entry(entry_id, state: "rollback")
    expect(fields.fetch("id")).to eq(entry_id)
    expect(fields.fetch("note")).to eq("owner note")
    expect(fields.fetch("locked")).to be(true)

    missing_id = ActiveRecord::Base.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i
    # A projection row with no prepared entry behind it: the reader must not fall back to it.
    create(:timesheet_entry, id: missing_id, user:, project:, note: "projection only")
    expect { owned_entry(missing_id, state: "rollback") }.to raise_error(StandardError)
  end
end

RSpec.describe "owned_entry in the legacy state", committed_data: true, owner_state: "legacy" do
  it "owned_entry in the legacy state returns the timesheet_entries row fields" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    entry_id = arrange_owned_entries([{ company:, user:, project:, note: "arranged note", duration: 90.0 }],
                                     state: "legacy").first
    TimesheetEntry.unscoped.find(entry_id).update_columns(note: "changed legacy note")

    # "`owned_entry(id, state: "legacy")` returns the `timesheet_entries` row's fields."
    fields = owned_entry(entry_id, state: "legacy")
    expect(fields.fetch("id")).to eq(entry_id)
    expect(fields.fetch("note")).to eq("changed legacy note")
    expect(fields.fetch("project_id")).to eq(project.id)
    expect(fields.fetch("user_id")).to eq(user.id)
  end
end

RSpec.describe "arrange_owned_entries against the live Timekeeping app", :without_transaction, committed_data: true do
  it "live arrange_owned_entries in the timekeeping state puts the entry in the Timekeeping database and a same-id projection" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    live = TimekeepingRegressionAdapter.current
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless live
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    entry_id = arrange_owned_entries([{ company:, user:, project:, note: "live entry" }], state: "timekeeping").first

    store = Timekeeping::Handoff::TimekeepingStore.new(base_url: live.base_url, token: live.service_token)
    timekeeping_ids = store.export_checkpoint.rows.fetch("entries").pluck("id")
    # "an entry created in the timekeeping state exists in the Timekeeping database and the projection"
    expect(timekeeping_ids).to include(entry_id)
    expect(TimesheetEntry.unscoped.where(id: entry_id).count).to eq(1)

    # "after arrange, a write at generation 2 is accepted."
    expect(live.admission_generation).to eq(2)
    token = Timekeeping::UserToken.mint(user:, company:, project_ids: [project.id], private_key: live.private_key)
    body = { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 30.0,
             "note" => "after arrange", "source" => "manual", "source_metadata" => {} }
    expect(live.write_entry(company_id: company.id, token:, body:).code.to_i).to eq(201)
  end
end

RSpec.describe "arrange_owned_entries advances the live Timekeeping entry sequence", :without_transaction, committed_data: true do
  it "live API create after arranging ids above and at the sequence's next value gets a new id and keeps every row" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    live = TimekeepingRegressionAdapter.current
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless live
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    store = Timekeeping::Handoff::TimekeepingStore.new(base_url: live.base_url, token: live.service_token)
    # The reset keeps the sequence rising across examples, so its next value is read here, not hard-coded.
    next_id = store.advance_entry_id_sequence(above: 0)

    # "Live: arrange an entry whose id is above the Timekeeping sequence's next value."
    # The entry at exactly next_id is what the API create would collide with if the advance were removed.
    arranged_ids = arrange_owned_entries([{ company:, user:, project:, id: next_id + 5, note: "above next" },
                                          { company:, user:, project:, id: next_id, note: "at next" }],
                                         state: "timekeeping")

    token = Timekeeping::UserToken.mint(user:, company:, project_ids: [project.id], private_key: live.private_key)
    body = { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 30.0,
             "note" => "api create", "source" => "manual", "source_metadata" => {} }
    response = live.write_entry(company_id: company.id, token:, body:)

    # "A later API create gets a new id, and both rows are kept in the Timekeeping database."
    expect(response.code.to_i).to eq(201)
    parsed = JSON.parse(response.body)
    created_id = parsed["id"] || parsed.dig("entry", "id")
    expect(arranged_ids).not_to include(created_id)
    timekeeping_ids = store.export_checkpoint.rows.fetch("entries").pluck("id")
    expect(timekeeping_ids).to include(next_id + 5, next_id, created_id)
  end
end

RSpec.describe "arrange_owned_entries keeps both live batches", :without_transaction, committed_data: true do
  it "live two arrange calls keep every id of both disjoint batches in the Timekeeping database" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    live = TimekeepingRegressionAdapter.current
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless live
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))

    first_batch = arrange_owned_entries([{ company:, user:, project:, note: "first a" },
                                         { company:, user:, project:, note: "first b" }], state: "timekeeping")
    second_batch = arrange_owned_entries([{ company:, user:, project:, note: "second a" }], state: "timekeeping")

    store = Timekeeping::Handoff::TimekeepingStore.new(base_url: live.base_url, token: live.service_token)
    timekeeping_ids = store.export_checkpoint.rows.fetch("entries").pluck("id")
    # "Every id from two disjoint batches is in the Timekeeping database."
    expect(first_batch & second_batch).to be_empty
    expect(timekeeping_ids).to include(*first_batch, *second_batch)
    expect(timekeeping_ids.tally.values_at(*first_batch, *second_batch)).to all(eq(1))
  end
end

RSpec.describe "owned_entry against the live Timekeeping app", :without_transaction, committed_data: true do
  it "live owned_entry in the timekeeping state returns the note loaded into the Timekeeping app, not the changed projection note" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    live = TimekeepingRegressionAdapter.current
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless live
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    entry_id = arrange_owned_entries([{ company:, user:, project:, note: "loaded note" }], state: "timekeeping").first
    TimesheetEntry.unscoped.find(entry_id).update_columns(note: "projection note")

    # "live, `owned_entry(id, state: "timekeeping")` returns the note loaded into the Timekeeping app, not the projection's"
    fields = owned_entry(entry_id, state: "timekeeping")
    expect(fields.fetch("id")).to eq(entry_id)
    expect(fields.fetch("note")).to eq("loaded note")
  end
end

RSpec.describe "arrange_owned_entries when the checkpoint load and the admit both fail", committed_data: true do
  it "timekeeping state: when load_checkpoint and admit both raise, admit still ran at generation 2 and the load error propagates" do
    load_error = Class.new(StandardError)
    admit_error = Class.new(StandardError)
    store = Class.new do
      attr_reader :calls

      def initialize(load_error, admit_error)
        @calls = []
        @load_error = load_error
        @admit_error = admit_error
      end

      def fence_admission = @calls << [:fence_admission]

      def load_checkpoint(_checkpoint)
        @calls << [:load_checkpoint]
        raise @load_error, "checkpoint refused"
      end

      def advance_entry_id_sequence(above:)
        @calls << [:advance_entry_id_sequence, above]
        above + 1
      end

      def admit(generation:)
        @calls << [:admit, generation]
        raise @admit_error, "admit refused"
      end
    end.new(load_error, admit_error)
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))

    # "If `admit` raises while another error propagates, the original error wins."
    expect do
      arrange_owned_entries([{ company:, user:, project: }], state: "timekeeping", timekeeping_store: store)
    end.to raise_error(load_error, "checkpoint refused")

    # "admission is restored at the state's admission generation even when `load_checkpoint` raises, and the original error propagates"
    expect(store.calls.map(&:first)).to eq(%i[fence_admission load_checkpoint admit])
    expect(store.calls.last).to eq([:admit, 2])
    expect(TimesheetEntry.unscoped.count).to eq(0)
  end
end

RSpec.describe "arrange_owned_entries with an id repeated inside one batch", committed_data: true do
  it "timekeeping state: an id repeated as 7 and \"7\" in one call raises ArgumentError before the store is called or any row is written" do
    store = Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def fence_admission = @calls << :fence_admission
      def load_checkpoint(_checkpoint) = @calls << :load_checkpoint
      def advance_entry_id_sequence(above:) = (@calls << :advance_entry_id_sequence) && (above + 1)
      def admit(generation:) = @calls << :admit
    end.new
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    expect do
      arrange_owned_entries(
        [{ id: 7, company:, user:, project: }, { id: "7", company:, user:, project: }],
        state: "timekeeping", timekeeping_store: store
      )
    end.to raise_error(ArgumentError)

    expect(store.calls).to be_empty
    expect(TimesheetEntry.unscoped.count).to eq(0)
  end
end

RSpec.describe "arrange_owned_entries with an id repeated across two calls", committed_data: true do
  it "rollback state: a second call repeating an id from the first raises ArgumentError and adds no entries, reservations or projection rows" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    first_id, = arrange_owned_entries([{ company:, user:, project: }], state: "rollback")
    reservation_count = -> { ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM reservations").to_i }
    counts_before = [Timekeeping::LocalEntry.count, TimesheetEntry.unscoped.count, reservation_count.call]

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    # The fresh row comes first, so a writer that checks row by row would write it before reaching the repeat.
    expect do
      arrange_owned_entries(
        [{ company:, user:, project: }, { id: first_id, company:, user:, project:, locked: true }],
        state: "rollback"
      )
    end.to raise_error(ArgumentError)

    expect([Timekeeping::LocalEntry.count, TimesheetEntry.unscoped.count, reservation_count.call]).to eq(counts_before)
  end
end

RSpec.describe "arrange_owned_entries retried after a failed checkpoint load", committed_data: true do
  it "timekeeping state: a batch whose load failed can be arranged again in the same example, and the retry loads it and advances above its id" do
    load_error = Class.new(StandardError)
    store = Class.new do
      attr_reader :calls

      def initialize(load_error)
        @calls = []
        @load_error = load_error
        @failures_left = 1
      end

      def fence_admission = @calls << [:fence_admission]

      def load_checkpoint(_checkpoint)
        @calls << [:load_checkpoint]
        return unless @failures_left.positive?

        @failures_left -= 1
        raise @load_error, "checkpoint refused once"
      end

      def advance_entry_id_sequence(above:)
        @calls << [:advance_entry_id_sequence, above]
        above + 1
      end

      def admit(generation:) = @calls << [:admit, generation]
    end.new(load_error)
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    entry_id = ApplicationRecord.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i
    rows = [{ id: entry_id, company:, user:, project: }]

    expect do
      arrange_owned_entries(rows, state: "timekeeping", timekeeping_store: store)
    end.to raise_error(load_error)

    # A failed load must not count its ids as arranged, or the retry would hit the
    # "A row id repeating one already arranged in the same example raises `ArgumentError`" rule falsely.
    expect(arrange_owned_entries(rows, state: "timekeeping", timekeeping_store: store)).to eq([entry_id])
    expect(store.calls).to include([:advance_entry_id_sequence, entry_id])
    expect(store.calls.last).to eq([:admit, 2])
    expect(TimesheetEntry.unscoped.where(id: entry_id).count).to eq(1)
  end
end

RSpec.describe "owned_entry for an id the owning store does not hold", committed_data: true do
  it "rollback state: owned_entry raises for an id that only has a timesheet_entries row instead of returning the projection" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    # The legacy writer fills timesheet_entries only, so no prepared entry holds this id.
    legacy_id, = arrange_owned_entries([{ company:, user:, project:, note: "projection only" }], state: "legacy")

    expect(TimesheetEntry.unscoped.find(legacy_id).note).to eq("projection only")
    expect(Timekeeping::LocalEntry.where(id: legacy_id)).not_to exist
    # "It reads one entry's fields from the owning store, never from the projection in the timekeeping and rollback states"
    expect { owned_entry(legacy_id, state: "rollback") }.to raise_error(StandardError)
  end
end

RSpec.describe "arrange_owned_entries in the timekeeping state without a live adapter", committed_data: true do
  it "timekeeping state with no live adapter and no injected store raises and writes no projection row" do
    skip "The live adapter is running in this run, so the no-adapter path cannot be reached" if TimekeepingRegressionAdapter.current

    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))

    # "With no adapter running, the timekeeping writer raises a clear error."
    # Falling back to timesheet_entries would put the rows back in the wrong store.
    expect do
      arrange_owned_entries([{ company:, user:, project: }], state: "timekeeping")
    end.to raise_error(StandardError)
    expect(TimesheetEntry.unscoped.count).to eq(0)
  end
end

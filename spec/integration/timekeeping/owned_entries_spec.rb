# frozen_string_literal: true

require "rails_helper"

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
    expect { arrange_owned_entries(rows, state: "timekeeping", timekeeping_store: store) }
      .to raise_error(load_failure, "load refused")
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

  it "live owned_entries in the timekeeping state reads the Timekeeping app, not the projection, and scopes by company only when one is given" do
    unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
      skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
    end
    skip "The live adapter is not running: select the timekeeping owner state and a _test TIMEKEEPING_DATABASE_URL" unless
      TimekeepingRegressionAdapter.current
    first, second = Array.new(2) do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user:)
      user.add_role(:admin, company)
      { company:, user:, project: create(:project, billable: true, client: create(:client, company:)) }
    end
    first_id, second_id = arrange_owned_entries(
      [first.merge(note: "loaded note"), second.merge(note: "other company")], state: "timekeeping"
    )
    TimesheetEntry.unscoped.find(first_id).update_columns(note: "projection note")
    # A row only the projection holds: Timekeeping does not own it, so it must not be read.
    TimesheetEntry.create!(user_id: first[:user].id, project_id: first[:project].id, work_date: Date.new(2026, 1, 5),
                           duration: 30, note: "projection only")

    company_rows = owned_entries(company: first[:company], state: "timekeeping")
    expect(company_rows.pluck("id", "note")).to eq([[first_id, "loaded note"]])
    expect(owned_entries(company: first[:company], state: "timekeeping", note: "projection note")).to eq([])
    expect(owned_entries(state: "timekeeping").pluck("id")).to include(first_id, second_id)
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
    reservation_count = -> { ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM reservations").to_i }
    prepared_counts_before = [Timekeeping::LocalEntry.count, reservation_count.call]

    # "A row id repeating one already arranged in the same example raises `ArgumentError` before anything is written."
    expect do
      arrange_owned_entries(
        [{ id: 7, company:, user:, project: }, { id: "7", company:, user:, project: }],
        state: "timekeeping", timekeeping_store: store
      )
    end.to raise_error(ArgumentError)

    expect(store.calls).to be_empty
    expect(TimesheetEntry.unscoped.count).to eq(0)
    expect([Timekeeping::LocalEntry.count, reservation_count.call]).to eq(prepared_counts_before)
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

RSpec.describe "arrange_owned_entries drawing ids past an explicit id", committed_data: true do
  it "legacy state: a row without id skips a sequence value already arranged as an explicit id" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    drawn = ApplicationRecord.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i
    # The sequence hands out drawn + 1 next, which this explicit id already holds.
    explicit_id, = arrange_owned_entries([{ company:, user:, project:, id: drawn + 1 }], state: "legacy")

    generated_id, = arrange_owned_entries([{ company:, user:, project:, note: "generated" }], state: "legacy")

    expect(generated_id).not_to eq(explicit_id)
    expect(TimesheetEntry.unscoped.where(id: [explicit_id, generated_id]).count).to eq(2)
  end
end

RSpec.describe "arrange_owned_entries moving the prepared entries sequence", committed_data: true do
  it "rollback state: a prepared entry created after arranging gets an id above every arranged id" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    arranged_ids = arrange_owned_entries([{ company:, user:, project: }, { company:, user:, project: }],
                                         state: "rollback")

    later = Timekeeping::LocalEntry.create!(
      TimekeepingContract::LocalOwnerArrange::ENTRY_DEFAULTS.merge("company_id" => company.id, "user_id" => user.id,
                                                                    "project_id" => project.id)
    )

    expect(later.id).to be > arranged_ids.max
  end
end

RSpec.describe "arrange_owned_entries when only the admit fails", committed_data: true do
  it "timekeeping state: an admit failure after a successful load propagates" do
    admit_error = Class.new(StandardError)
    store = Class.new do
      attr_reader :calls

      def initialize(admit_error)
        @calls = []
        @admit_error = admit_error
      end

      def fence_admission = @calls << [:fence_admission]
      def load_checkpoint(checkpoint) = (@calls << [:load_checkpoint]) && checkpoint

      def advance_entry_id_sequence(above:)
        @calls << [:advance_entry_id_sequence, above]
        above + 1
      end

      def admit(generation:)
        @calls << [:admit, generation]
        raise @admit_error, "admit refused"
      end
    end.new(admit_error)
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    entry_id = ApplicationRecord.connection.select_value(
      "SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))"
    ).to_i

    expect do
      arrange_owned_entries([{ id: entry_id, company:, user:, project: }], state: "timekeeping",
                                                                           timekeeping_store: store)
    end.to raise_error(admit_error, "admit refused")
    expect(store.calls.last).to eq([:admit, 2])
    expect(TimesheetEntry.unscoped.where(id: entry_id)).not_to exist
  end
end

RSpec.describe "arrange_owned_entries keeping non-default fixture values", committed_data: true do
  it "each state keeps a row's work date, duration and bill status in the owner and the projection" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    values = { work_date: "2026-04-15", duration: 90.0, bill_status: "non_billable" }
    expected = [Date.new(2026, 4, 15), 90.0, "non_billable"]
    loaded_rows = []
    store = Object.new
    store.define_singleton_method(:fence_admission) { nil }
    store.define_singleton_method(:load_checkpoint) { |checkpoint| loaded_rows.replace(checkpoint.rows.fetch("entries")) }
    store.define_singleton_method(:advance_entry_id_sequence) { |above:| above + 1 }
    store.define_singleton_method(:admit) { |generation:| nil }
    projection_values = ->(id) { TimesheetEntry.unscoped.find(id).then { [_1.work_date, _1.duration, _1.bill_status] } }

    legacy_id, = arrange_owned_entries([{ company:, user:, project:, **values }], state: "legacy")
    expect(projection_values.call(legacy_id)).to eq(expected)

    rollback_id, = arrange_owned_entries([{ company:, user:, project:, **values }], state: "rollback")
    owner = Timekeeping::LocalEntry.find(rollback_id)
    expect([owner.work_date, owner.duration, owner.bill_status]).to eq(expected)
    expect(projection_values.call(rollback_id)).to eq(expected)

    timekeeping_id, = arrange_owned_entries([{ company:, user:, project:, **values }], state: "timekeeping",
                                                                                     timekeeping_store: store)
    loaded = loaded_rows.find { |row| row.fetch("id") == timekeeping_id }
    expect(loaded.values_at("work_date", "duration", "bill_status")).to eq(expected)
    expect(projection_values.call(timekeeping_id)).to eq(expected)
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

RSpec.describe "owned_entry in the rollback state", committed_data: true, owner_state: "rollback" do
  it "owned_entries in the rollback state reads the prepared store, skips projection-only rows, and scopes by company only when one is given" do
    tenants = Array.new(2) do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user:)
      user.add_role(:admin, company)
      project = create(:project, billable: true, client: create(:client, company:))
      { company:, user:, project: }
    end
    first, second = tenants

    first_ids = arrange_owned_entries([first.merge(note: "owned one"), first.merge(note: "owned two")], state: "rollback")
    second_ids = arrange_owned_entries([second.merge(note: "other company")], state: "rollback")
    # A row only the projection holds: the prepared store does not own it, so it must not be counted.
    create(:timesheet_entry, project: first[:project], user: first[:user], note: "projection only")

    # "Replace its `Timekeeping::LocalEntry` and projection counts, which are direct store reads, with a count of the entries the owning store holds for the company."
    company_rows = owned_entries(company: first[:company], state: "rollback")
    expect(company_rows.map { |row| row.fetch("id") }).to match_array(first_ids)
    expect(company_rows.map { |row| row.fetch("note") }).not_to include("projection only", "other company")

    # A global read keeps its global reach, so a write under another company is still seen.
    every_row = owned_entries(state: "rollback")
    expect(every_row.map { |row| row.fetch("id") }).to include(*first_ids, *second_ids)
    expect(every_row.map { |row| row.fetch("note") }).not_to include("projection only")
  end
end

RSpec.describe "owned_entry in the rollback state", committed_data: true, owner_state: "rollback" do
  it "owned_entries in the rollback state leaves a discarded prepared entry out by default and counts it with include_discarded" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    kept_id, discarded_id = arrange_owned_entries(
      [{ company:, user:, project:, note: "kept" }, { company:, user:, project:, note: "discarded" }],
      state: "rollback"
    )
    Timekeeping::LocalEntry.find(discarded_id).update_columns(discarded_at: Time.current)

    expect(owned_entries(company:, state: "rollback").map { |row| row.fetch("id") }).to eq([kept_id])
    expect(owned_entries(company:, state: "rollback", include_discarded: true).map { |row| row.fetch("id") })
      .to contain_exactly(kept_id, discarded_id)
  end
end

RSpec.describe "owned_entry in the legacy state", committed_data: true, owner_state: "legacy" do
  it "owned_entries in the legacy state narrows by note, duration, project and user, counts discarded rows only on request, and rejects an unknown filter" do
    company = create(:company)
    paul = create(:user, current_workspace_id: company.id)
    jane = create(:user, current_workspace_id: company.id)
    [paul, jane].each { |user| create(:employment, company:, user:) }
    website = create(:project, billable: true, client: create(:client, company:))
    # Billable, because the fixture rows default to unbilled and a non-billable project refuses them.
    internal = create(:project, billable: true, client: create(:client, company:))
    match_id, other_duration_id, other_project_id, other_user_id, discarded_id = arrange_owned_entries(
      [
        { company:, user: paul, project: website, note: "same work", duration: 60 },
        { company:, user: paul, project: website, note: "same work", duration: 90 },
        { company:, user: paul, project: internal, note: "same work", duration: 60 },
        { company:, user: jane, project: website, note: "same work", duration: 60 },
        { company:, user: paul, project: website, note: "gone", duration: 60 }
      ],
      state: "legacy"
    )
    TimesheetEntry.unscoped.find(discarded_id).update_columns(discarded_at: Time.current)

    ids = ->(rows) { rows.map { |row| row.fetch("id") } }
    expect(ids.call(owned_entries(company:, state: "legacy", note: "same work")))
      .to contain_exactly(match_id, other_duration_id, other_project_id, other_user_id)
    expect(ids.call(owned_entries(company:, state: "legacy", note: "same work", duration: 60, project_id: website.id,
                                  user_id: paul.id))).to eq([match_id])
    expect(owned_entries(company:, state: "legacy", note: "gone")).to be_empty
    expect(ids.call(owned_entries(company:, state: "legacy", note: "gone", include_discarded: true))).to eq([discarded_id])

    expect { owned_entries(company:, state: "legacy", invoice_id: 1) }.to raise_error(ArgumentError)
    expect { owned_entries(company:, state: "handoff") }.to raise_error(ArgumentError)
  end
end

RSpec.describe "arrange_owned_entries", committed_data: true do
  it "owned_entries in the rollback state returns only the given company's prepared entries and never another company's" do
    first_company, second_company = Array.new(2) { create(:company) }
    first_user = create(:user, current_workspace_id: first_company.id)
    second_user = create(:user, current_workspace_id: second_company.id)
    first_project = create(:project, billable: true, client: create(:client, company: first_company))
    second_project = create(:project, billable: true, client: create(:client, company: second_company))

    first_id, second_id = arrange_owned_entries(
      [{ company: first_company, user: first_user, project: first_project, note: "tenant one row" },
       { company: second_company, user: second_user, project: second_project, note: "tenant two row" }],
      state: "rollback"
    )

    first_rows = owned_entries(company: first_company, state: "rollback")
    expect(first_rows.map { |row| row.fetch("id") }).to eq([first_id])
    expect(first_rows.map { |row| row.fetch("company_id") }).to all(eq(first_company.id))

    second_rows = owned_entries(company: second_company, state: "rollback")
    expect(second_rows.map { |row| row.fetch("id") }).to eq([second_id])
    expect(second_rows.map { |row| row.fetch("note") }).not_to include("tenant one row")
  end
end

RSpec.describe "arrange_owned_entries", committed_data: true do
  it "owned_entries in the legacy state keeps one company's entries apart and reads every company only when no company is given" do
    first_company, second_company = Array.new(2) { create(:company) }
    first_user = create(:user, current_workspace_id: first_company.id)
    second_user = create(:user, current_workspace_id: second_company.id)
    first_project = create(:project, billable: true, client: create(:client, company: first_company))
    second_project = create(:project, billable: true, client: create(:client, company: second_company))

    first_id, second_id = arrange_owned_entries(
      [{ company: first_company, user: first_user, project: first_project, note: "same note" },
       { company: second_company, user: second_user, project: second_project, note: "same note" }],
      state: "legacy"
    )

    # The same note under another company must not leak into a company-scoped read.
    scoped = owned_entries(company: first_company, state: "legacy", note: "same note")
    expect(scoped.map { |row| row.fetch("id") }).to eq([first_id])

    # A global read keeps its reach, so a stray write under another company is still seen.
    global_ids = owned_entries(state: "legacy", note: "same note").map { |row| row.fetch("id") }
    expect(global_ids).to include(first_id, second_id)
  end
end

RSpec.describe "arrange_owned_entries", committed_data: true do
  it "owned_entries returns nothing when a company read is filtered by another company's project or user" do
    first_company, second_company = Array.new(2) { create(:company) }
    first_user = create(:user, current_workspace_id: first_company.id)
    second_user = create(:user, current_workspace_id: second_company.id)
    first_project = create(:project, billable: true, client: create(:client, company: first_company))
    second_project = create(:project, billable: true, client: create(:client, company: second_company))

    %w[legacy rollback].each do |state|
      arrange_owned_entries(
        [{ company: first_company, user: first_user, project: first_project, note: "#{state} one" },
         { company: second_company, user: second_user, project: second_project, note: "#{state} two" }],
        state:
      )

      # A filter naming another company's project or user cannot widen a company-scoped read.
      expect(owned_entries(company: first_company, state:, project_id: second_project.id)).to eq([])
      expect(owned_entries(company: first_company, state:, user_id: second_user.id)).to eq([])
      expect(owned_entries(company: first_company, state:, project_id: first_project.id).size).to eq(1)
    end
  end
end

RSpec.describe "owned_entries", committed_data: true do
  # "Replace its `Timekeeping::LocalEntry` and projection counts, which are direct store reads, with a count of the entries the owning store holds for the company."
  it "owned_entries in the rollback state counts the prepared store's entries, not projection-only rows, and scopes by company only when one is given" do
    tenants = Array.new(2) do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user:)
      user.add_role(:admin, company)
      project = create(:project, billable: true, client: create(:client, company:))
      { company:, user:, project: }
    end
    first, second = tenants

    first_ids = arrange_owned_entries(
      [first.merge(note: "owned one"), first.merge(note: "owned two")], state: "rollback"
    )
    arrange_owned_entries([second.merge(note: "other company")], state: "rollback")
    # A projection row with no prepared-store owner: the owner does not hold it.
    TimesheetEntry.create!(user_id: first[:user].id, project_id: first[:project].id, work_date: Date.new(2026, 1, 5),
                           duration: 30, note: "projection only", bill_status: "unbilled")

    company_rows = owned_entries(company: first[:company], state: "rollback")
    expect(company_rows.map { |row| row.fetch("id") }).to match_array(first_ids)
    expect(company_rows.map { |row| row.fetch("note") }).not_to include("projection only", "other company")

    # With no company, a global check still sees an entry written under another company.
    all_notes = owned_entries(state: "rollback").map { |row| row.fetch("note") }
    expect(all_notes).to include("owned one", "owned two", "other company")
    expect(all_notes).not_to include("projection only")
  end
end

RSpec.describe "owned_entries", committed_data: true do
  # "Adapt only the assertions that read a store directly. The behaviour they pin stays the same."
  # A replaced `.kept` read must not count discarded rows, and a read that counted them must still be able to.
  it "owned_entries in the legacy state leaves discarded entries out unless asked, filters by note and duration together, and rejects an unknown filter" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role(:admin, company)
    project = create(:project, billable: true, client: create(:client, company:))
    row = { company:, user:, project: }

    kept_id, same_note_other_duration_id, discarded_id = arrange_owned_entries(
      [row.merge(note: "same work", duration: 60), row.merge(note: "same work", duration: 90),
       row.merge(note: "same work", duration: 60)],
      state: "legacy"
    )
    TimesheetEntry.unscoped.find(discarded_id).discard!

    kept = owned_entries(company:, state: "legacy", note: "same work", duration: 60)
    expect(kept.map { |entry| entry.fetch("id") }).to eq([kept_id])

    with_discarded = owned_entries(company:, state: "legacy", include_discarded: true, note: "same work", duration: 60)
    expect(with_discarded.map { |entry| entry.fetch("id") }).to contain_exactly(kept_id, discarded_id)

    expect(owned_entries(company:, state: "legacy", note: "same work").map { |entry| entry.fetch("id") })
      .to contain_exactly(kept_id, same_note_other_duration_id)
    expect(owned_entries(company:, state: "legacy", note: "no such note")).to eq([])

    expect { owned_entries(company:, state: "legacy", colour: "red") }.to raise_error(ArgumentError)
    expect { owned_entries(company:, state: "handoff") }.to raise_error(ArgumentError)
  end
end

RSpec.describe "arrange_owned_entries", :without_transaction, committed_data: true do
  it "owned_entries in the rollback state ignores projection-only rows and keeps company and discarded scope as asked" do
    tenants = Array.new(2) do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user:)
      user.add_role(:admin, company)
      project = create(:project, billable: true, client: create(:client, company:))
      { company:, user:, project: }
    end
    first, second = tenants

    kept_id, discarded_id, = arrange_owned_entries(
      [first.merge(note: "kept"), first.merge(note: "discarded"), second.merge(note: "other company")],
      state: "rollback"
    )
    Timekeeping::LocalEntry.where(id: discarded_id).update_all(discarded_at: Time.current)
    # A row only the projection holds: the prepared store does not own it, so it must never be counted.
    TimesheetEntry.create!(user_id: first[:user].id, project_id: first[:project].id, work_date: Date.new(2026, 1, 5),
                           duration: 60, note: "projection only")

    # "Adapt only the assertions that read a store directly. The behaviour they pin stays the same."
    expect(owned_entries(company: first[:company], state: "rollback").pluck("id")).to eq([kept_id])
    expect(owned_entries(company: first[:company], state: "rollback", include_discarded: true).pluck("id"))
      .to contain_exactly(kept_id, discarded_id)
    # A global read keeps its reach, so a stray write under another company is still seen.
    expect(owned_entries(state: "rollback").pluck("note")).to contain_exactly("kept", "other company")
    expect(owned_entries(company: first[:company], state: "rollback", note: "projection only")).to eq([])
  end
end

RSpec.describe "arrange_owned_entries", :without_transaction, committed_data: true do
  it "owned_entries refuses an unknown filter key or state instead of silently matching every entry" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    project = create(:project, billable: true, client: create(:client, company:))
    arrange_owned_entries([{ company:, user:, project:, note: "only" }], state: "legacy")

    # A misspelt filter ignored would widen the read, so an assertion of zero rows could pass while entries exist.
    expect { owned_entries(company:, state: "legacy", notes: "only") }.to raise_error(ArgumentError)
    expect { owned_entries(company:, state: "Legacy") }.to raise_error(ArgumentError)
    expect(owned_entries(company:, state: "legacy", note: "only").size).to eq(1)
  end
end

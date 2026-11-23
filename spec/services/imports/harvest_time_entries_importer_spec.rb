# frozen_string_literal: true

require "rails_helper"

# Runs an import, then delivers the rows it wrote to timesheet_entries through
# the outbox relay and waits until they are delivered. Where the prepared store
# owns the entries (rollback), or a live Timekeeping app owns them in a live
# regression run, the relay is the only writer of timesheet_entries, and the
# importer reads that table to skip rows already stored, so a later import must
# find them delivered. In other states the delivery does nothing.
module HarvestImporterSpecRelay
  def run_harvest_import(import)
    described_class.new(import).process
    relay_local_entries_to_projection(import.company)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  include HarvestImporterSpecRelay

  let(:company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:actor) { create(:user, current_workspace_id: company.id) }
  let(:paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: company.id) }
  let(:jane) { create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: company.id) }
  let(:data_import) { create(:data_import, company:, user: actor, options:) }
  let(:options) { {} }
  let(:fixture_path) { Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv") }

  before do
    create(:employment, company:, user: actor)
    # Only owners and admins may create an import (DataImportPolicy#create?).
    actor.add_role :admin, company
    create(:employment, company:, user: paul)
    create(:employment, company:, user: jane)
    attach_csv(data_import, fixture_path)
  end

  it "creates clients, projects, members, and entries with Harvest values" do
    expect_owner_state!
    run_harvest_import(data_import)

    expect(data_import.reload).to have_attributes(
      status: "completed",
      total_rows: 12,
      imported_rows: 11,
      failed_rows: 0,
      skipped_rows: 1
    )
    expect(company.clients.kept.pluck(:name)).to contain_exactly("Acme LLC", "Very Long Client Name T-715152")
    expect(company.projects.kept.count).to eq(3)
    expect(ProjectMember.kept.joins(project: :client).where(clients: { company_id: company.id }).count).to eq(3)

    website = company.projects.kept.find_by!(name: "Website")
    expect(website).to have_attributes(billable: true, description: "Harvest project code: WEB")
    expect(owned_entries(project_id: website.id, note: "Meeting - Daily sync").size).to eq(2)

    first_entry = owned_entries(project_id: website.id, note: "Programming - Built landing\nand tests").fetch(0)
    expect(first_entry).to include("duration" => 75, "bill_status" => "unbilled", "source" => "import")
    expect(first_entry["source_metadata"]).to eq("tool" => "harvest")
    expect(owned_entries(project_id: website.id, duration: 1523).fetch(0)).to include("bill_status" => "billed")
    internal = company.projects.kept.find_by!(name: "Internal")
    expect(internal).not_to be_billable
    expect(owned_entries(project_id: internal.id)).to all(include("bill_status" => "non_billable"))
    expect(company.clients.kept.find_by!(name: "Very Long Client Name T-715152").currency).to eq("USD")
    expect(website.project_members.kept.find_by!(user: paul).hourly_rate).to eq(150)
  end

  it "tags imported records with the import source and reports completion" do
    Rails.event.set_context(source: "cli")
    expect_owner_state!
    completed = assert_event_reported("Imports::Completed") { run_harvest_import(data_import) }

    expect(completed[:payload].to_h).to include(actor: { id: actor.id, type: "User" })
    expect(completed[:payload].to_h[:data]).to include(id: data_import.id, imported_rows: 11)
    expect(RailsEventViewer.events.with_context(:data_import_id, data_import.id.to_s).count).to be_positive

    following_event = assert_event_reported("after_import") { Rails.event.notify("after_import") }
    expect(following_event[:context]).to eq(source: "cli")
  end

  # TimesheetEntry's after_create is the only emitter of this event, so it
  # fires only where the legacy store owns the entries.
  it "reports each legacy entry it creates with the import's event context", writes_legacy_store: true do
    Rails.event.set_context(source: "cli")
    expect_owner_state!
    entry_event = assert_event_reported("TimesheetEntries::Created") { run_harvest_import(data_import) }

    expect(entry_event[:context]).to include(source: "harvest_import", data_import_id: data_import.id.to_s)
  end

  # Where the prepared store or Timekeeping owns the entries, the gateway's
  # per-row write is left out of the count: there the owner reads the company
  # and project memberships for every row to check the write, which is the
  # owner's check, not the importer's batching. The live Timekeeping app reads
  # them through this process's database pool, so its reads would otherwise be
  # counted here. Where the legacy store owns the entries the whole import is
  # counted.
  it "avoids per-row project membership and company queries" do
    select_queries = 0
    project_member_queries = 0
    company_queries = 0
    inside_gateway_import = false
    owner_checks_each_write = Timekeeping::EntryOwner.for(TimekeepingOwnership.current) != :legacy
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      inside_gateway_import = owner_checks_each_write
      original.call(*args, **kwargs)
    ensure
      inside_gateway_import = false
    end
    subscriber = lambda do |*, payload|
      sql = payload[:sql]
      next if inside_gateway_import || !sql.start_with?("SELECT")

      select_queries += 1
      project_member_queries += 1 if sql.include?('FROM "project_members"')
      company_queries += 1 if sql.include?('FROM "companies"')
    end

    expect_owner_state!
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.new(data_import).process
    end

    expect(select_queries).to be < 66
    expect(project_member_queries).to be < 6
    expect(company_queries).to be < 6
  end

  it "matches users by name and rounds decimal hours to minutes" do
    expect_owner_state!
    run_harvest_import(data_import)

    advisory = company.projects.kept.find_by!(name: "Advisory")
    entry = owned_entries(project_id: advisory.id, note: "Research - Memo").fetch(0)
    expect(entry).to include("user_id" => jane.id, "duration" => 80)
    expect(data_import.reload.summary.dig("users", "matched")).to include(
      "Jane Doe" => "jane@example.com",
      "Paul Connors" => "paul@example.com"
    )
  end

  context "with a user map" do
    let(:jane) { create(:user, first_name: "Janet", last_name: "Smith", email: "jane@example.com", current_workspace_id: company.id) }
    let(:options) { { "user_map" => { "Jane Doe" => "jane@example.com" } } }

    it "maps a Harvest name to a workspace email" do
      expect_owner_state!
      run_harvest_import(data_import)

      advisory = company.projects.kept.find_by!(name: "Advisory")
      expect(owned_entries(project_id: advisory.id).pluck("user_id")).to all(eq(jane.id))
    end
  end

  context "with an unmatched user" do
    before { jane.employments.find_by!(company:).discard! }

    it "records an error for every unmatched row and continues" do
      expect_owner_state!
      run_harvest_import(data_import)

      expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 7, failed_rows: 4)
      expect(data_import.row_errors).to all(include("message" => include("No team member in this Miru workspace matches Harvest user \"Jane Doe\"")))
      expect(data_import.summary.dig("users", "unmatched")).to eq(["Jane Doe"])
    end
  end

  context "with an ambiguous user name" do
    before do
      duplicate = create(:user, first_name: "paul", last_name: "CONNORS", current_workspace_id: company.id)
      create(:employment, company:, user: duplicate)
    end

    it "requires an explicit user mapping" do
      expect_owner_state!
      run_harvest_import(data_import)

      messages = data_import.reload.row_errors.pluck("message")
      expect(messages).to all(eq(
        "Harvest user \"Paul Connors\" matches more than one team member; pass --map \"Paul Connors=their@email\"."
      ))
      expect(data_import.summary.dig("users", "unmatched")).to include("Paul Connors")
    end
  end

  context "with assign_unmatched_to" do
    let(:fallback) { create(:user, first_name: "Fallback", last_name: "User", email: "fallback@example.com", current_workspace_id: company.id) }
    let(:options) { { "assign_unmatched_to" => "fallback@example.com" } }

    before do
      jane.employments.find_by!(company:).discard!
      create(:employment, company:, user: fallback)
    end

    it "assigns otherwise unmatched rows to the selected user" do
      expect_owner_state!
      run_harvest_import(data_import)

      expect(data_import.reload.failed_rows).to eq(0)
      advisory = company.projects.kept.find_by!(name: "Advisory")
      expect(owned_entries(project_id: advisory.id).pluck("user_id")).to all(eq(fallback.id))
    end
  end

  context "with a dry run" do
    let(:data_import) { create(:data_import, company:, user: actor, options:, dry_run: true) }

    it "only writes import bookkeeping and reports the plan" do
      expect_owner_state!
      expect do
        run_harvest_import(data_import)
      end.not_to change { [Client.count, Project.count, ProjectMember.count, owned_entries(include_discarded: true).size] }

      expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 0, skipped_rows: 1)
      expect(data_import.summary).to include(
        "rows" => 12,
        "entries_to_create" => 11,
        "zero_hour_skipped" => 1,
        "duplicates_skipped" => 0
      )
      expect(data_import.summary.dig("clients", "to_create")).to contain_exactly("Acme LLC", "Very Long Client Name T-715152")
      expect(data_import.summary.dig("projects", "to_create")).to contain_exactly(
        "Acme LLC / Internal",
        "Acme LLC / Website",
        "Very Long Client Name T-715152 / Advisory"
      )
      expect(data_import.summary.dig("date_range")).to eq("from" => "2026-01-02", "to" => "2026-01-11")
      expect(data_import.summary).not_to have_key("row_errors")
    end
  end

  it "matches users, clients, and projects case-insensitively" do
    paul.update!(first_name: "PAUL", last_name: "connors")
    client = create(:client, company:, name: "acme llc")
    project = create(:project, client:, name: "website", billable: true)

    expect_owner_state!
    run_harvest_import(data_import)

    expect(company.clients.where("LOWER(name) = ?", "acme llc").count).to eq(1)
    expect(client.projects.where("LOWER(name) = ?", "website").count).to eq(1)
    expect(owned_entries(project_id: project.id, user_id: paul.id)).not_to be_empty
  end

  it "parses dates using the company day-month-year format" do
    company.update!(date_format: "DD-MM-YYYY")
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      07-01-2026,Acme LLC,Website,1,Paul,Connors
    CSV

    expect_owner_state!
    run_harvest_import(data_import)

    # The live Timekeeping export is JSON, so its rows carry work_date as a string.
    expect(owned_entries(company:).sole.fetch("work_date").to_date).to eq(Date.new(2026, 1, 7))
  end

  it "keeps project names distinct when their 30-character prefixes collide" do
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Project Code,Hours,First Name,Last Name
      2026-01-01,Acme LLC,Acme 1H 2025 Committed Hours (PC),PC,1,Paul,Connors
    CSV

    expect_owner_state!
    run_harvest_import(data_import)

    second_import = create(:data_import, company:, user: actor)
    attach_csv_contents(second_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-02,Acme LLC,Acme 1H 2025 Committed Hours (LW),1,Paul,Connors
    CSV
    run_harvest_import(second_import)

    projects = company.projects.kept.order(:name)
    expect(projects.pluck(:name).uniq.size).to eq(2)
    expect(projects.pluck(:name).map(&:length)).to all(be <= 30)
    expect(projects.pluck(:description)).to contain_exactly(
      "Harvest project: Acme 1H 2025 Committed Hours (LW)",
      "Harvest project: Acme 1H 2025 Committed Hours (PC)\nHarvest project code: PC"
    )
    work_dates = projects.flat_map { |project| owned_entries(project_id: project.id).pluck("work_date") }
    expect(work_dates.map(&:to_date)).to contain_exactly(
      Date.new(2026, 1, 1),
      Date.new(2026, 1, 2)
    )
    expect(data_import.reload.summary["warnings"]).to include(match(/Project name truncated:/))

    reimport = create(:data_import, company:, user: actor)
    attach_csv_contents(reimport, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-02,Acme LLC,Acme 1H 2025 Committed Hours (LW),1,Paul,Connors
      2026-01-01,Acme LLC,Acme 1H 2025 Committed Hours (PC),1,Paul,Connors
    CSV

    expect do
      run_harvest_import(reimport)
    end.not_to change { [company.projects.kept.count, owned_entries.size, owned_entries(include_discarded: true).size] }
    expect(reimport.reload).to have_attributes(imported_rows: 0, skipped_rows: 2)
  end

  it "keeps client names distinct when their 30-character prefixes collide" do
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-01,Acme Corporate Legal Services Alpha,Website,1,Paul,Connors
    CSV

    expect_owner_state!
    run_harvest_import(data_import)

    second_import = create(:data_import, company:, user: actor)
    attach_csv_contents(second_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-02,Acme Corporate Legal Services Bravo,Website,1,Paul,Connors
    CSV
    run_harvest_import(second_import)

    expect(company.clients.kept.pluck(:name).uniq.size).to eq(2)
    expect(company.projects.kept.count).to eq(2)
    expect(data_import.reload.summary["warnings"]).to include(match(/Client name truncated:/))
  end

  it "reuses unambiguous client and project names created by the legacy importer" do
    client_name = "Acme Corporate Legal Services Alpha"
    project_name = "Acme 1H 2025 Committed Hours (PC)"
    create(:data_import, company:, user: actor, status: "completed", summary: {
      "warnings" => ["Client name truncated: #{client_name}", "Project name truncated: #{project_name}"]
    })
    legacy_client = create(:client, company:, name: client_name.first(30))
    legacy_project = create(:project, client: legacy_client, name: project_name.first(30))
    # A projection write: it stands in for the row the legacy importer left in
    # timesheet_entries, which the importer reads to skip a row already stored.
    create(:timesheet_entry, project: legacy_project, user: paul, work_date: Date.new(2026, 1, 1), duration: 60, note: "", source: "import")
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-01,#{client_name},#{project_name},1,Paul,Connors
    CSV

    expect_owner_state!
    expect do
      run_harvest_import(data_import)
    end.not_to change {
      [company.clients.count, company.projects.count, TimesheetEntry.count, owned_entries(include_discarded: true).size]
    }

    expect(data_import.reload).to have_attributes(imported_rows: 0, skipped_rows: 1)
  end

  it "records invalid hours, date, and blank client rows without creating entries" do
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-01,Acme LLC,Website,abc,Paul,Connors
      31-31-2026,Acme LLC,Website,1,Paul,Connors
      2026-01-03,,Website,1,Paul,Connors
    CSV

    expect_owner_state!
    expect do
      run_harvest_import(data_import)
    end.not_to change { owned_entries(include_discarded: true).size }

    expect(data_import.reload.row_errors).to eq([
      { "row" => 2, "message" => "Hours is invalid" },
      { "row" => 3, "message" => "Date is invalid: 31-31-2026" },
      { "row" => 4, "message" => "Client is blank" }
    ])
  end

  it "skips entries already imported without de-duplicating rows within the file" do
    expect_owner_state!
    run_harvest_import(data_import)
    second_import = create(:data_import, company:, user: actor)
    attach_csv(second_import, fixture_path)

    expect do
      run_harvest_import(second_import)
    end.not_to change { owned_entries(include_discarded: true).size }

    expect(second_import.reload).to have_attributes(imported_rows: 0, skipped_rows: 12)
    expect(second_import.summary["duplicates_skipped"]).to eq(11)
    expect(second_import.summary["date_range"]).to eq("from" => "2026-01-02", "to" => "2026-01-11")
  end

  it "rejects files missing required headers" do
    invalid_import = create(:data_import, company:, user: actor)
    invalid_import.file.attach(io: StringIO.new("Date,Client\n2026-01-01,Acme\n"), filename: "invalid.csv", content_type: "text/csv")

    expect_owner_state!
    expect do
      described_class.new(invalid_import).process
    end.to raise_error(described_class::InvalidFileError, /Missing required headers: Project, Hours, First Name, Last Name/)
  end

  it "reports client name truncation" do
    expect_owner_state!
    run_harvest_import(data_import)

    expect(data_import.reload.summary["warnings"]).to include(
      "Client name truncated: Very Long Client Name That Exceeds Thirty Characters"
    )
  end

  it "shortens long project names deterministically" do
    client = create(:client, company:, name: "Acme LLC")
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-01,Acme LLC,A Project Name Longer Than Thirty Characters,1,Paul,Connors,Yes
    CSV

    expect_owner_state!
    run_harvest_import(data_import)

    project = client.projects.find_by!(name: "A Project Name Longer T-ae2f52")
    expect(owned_entries(project_id: project.id)).not_to be_empty
    expect(data_import.reload.summary["warnings"]).to include(
      "Project name truncated: A Project Name Longer Than Thirty Characters"
    )

    reimport = create(:data_import, company:, user: actor)
    attach_csv_contents(reimport, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-01,Acme LLC,A PROJECT NAME LONGER THAN THIRTY CHARACTERS,1,Paul,Connors,Yes
    CSV

    expect do
      run_harvest_import(reimport)
    end.not_to change { [client.projects.count, owned_entries.size, owned_entries(include_discarded: true).size] }
  end

  it "restores an archived client before importing entries" do
    client = create(:client, company:, name: "Acme LLC")
    client.discard!

    expect_owner_state!
    run_harvest_import(data_import)

    expect(client.reload).to be_kept
    expect(owned_entries(project_id: client.projects.kept.find_by!(name: "Website").id)).not_to be_empty
    expect(data_import.reload.summary["warnings"]).to include("Restored archived client: Acme LLC")
  end

  it "restores an archived project before importing entries" do
    client = create(:client, company:, name: "Acme LLC")
    project = create(:project, client:, name: "Website", billable: true)
    project.discard!

    expect_owner_state!
    run_harvest_import(data_import)

    expect(project.reload).to be_kept
    expect(owned_entries(project_id: project.id)).not_to be_empty
    expect(data_import.reload.summary["warnings"]).to include("Restored archived project: Acme LLC / Website")
  end

  it "schedules the uploaded CSV for purge after a real run" do
    expect_owner_state!
    expect do
      run_harvest_import(data_import)
    end.to have_enqueued_job(ActiveStorage::PurgeJob).with(data_import.file.blob)
  end

  it "keeps an existing non-billable project non-billable and warns once" do
    client = create(:client, company:, name: "Acme LLC")
    project = create(:project, client:, name: "Website", billable: false)

    expect_owner_state!
    run_harvest_import(data_import)

    expect(owned_entries(project_id: project.id)).to all(include("bill_status" => "non_billable"))
    warnings = data_import.reload.summary["warnings"].grep(/Acme LLC \/ Website/)
    expect(warnings).to contain_exactly("Harvest marks Acme LLC / Website billable, but the Miru project is non-billable")
  end

  def attach_csv(import, path)
    File.open(path) do |file|
      import.file.attach(io: file, filename: File.basename(path), content_type: "text/csv")
    end
  end

  def attach_csv_contents(import, contents)
    import.file.attach(io: StringIO.new(contents), filename: "harvest.csv", content_type: "text/csv")
  end

  context "more tests 2" do
    # The counts read the store that owns entries in the selected state, so a
    # duplicate write fails this example whichever store owns them.
    it "stores the Harvest file's multi-line note once and a reimport adds no entry" do
      expect_owner_state!
      run_harvest_import(data_import)

      expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 11, failed_rows: 0)
      website = company.projects.kept.find_by!(name: "Website")
      note = "Programming - Built landing\nand tests"
      expect(owned_entries(project_id: website.id, note:).size).to eq(1)
      owned_count = owned_entries(company:).size
      expect(owned_count).to eq(11)

      reimport = create(:data_import, company:, user: actor, options: {})
      attach_csv(reimport, fixture_path)
      run_harvest_import(reimport)

      expect(owned_entries(company:).size).to eq(owned_count)
      expect(owned_entries(project_id: website.id, note:).size).to eq(1)
    end
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  let(:departed_company) { create(:company) }
  let(:departed_actor) { create(:user, current_workspace_id: departed_company.id) }
  let(:departed_paul) { create(:user, first_name: "Paul", last_name: "Connors", current_workspace_id: departed_company.id) }
  let(:departed_import) { create(:data_import, company: departed_company, user: departed_actor, options: {}) }

  before do
    create(:employment, company: departed_company, user: departed_actor)
    create(:employment, company: departed_company, user: departed_paul)
    create(:project, name: "Website", billable: false, client: create(:client, company: departed_company, name: "Acme LLC"))
    departed_import.file.attach(
      io: StringIO.new("Date,Client,Project,Hours,First Name,Last Name\n2026-01-01,Acme LLC,Website,1,Paul,Connors\n"),
      filename: "harvest.csv", content_type: "text/csv"
    )
  end

  # "A data import whose user has left the company fails the job."
  # The legacy store mints no token, so this holds only if the importer checks the user's employment itself.
  it "fails a legacy import whose data import user has left the company and writes no entry" do
    Employment.where(company: departed_company, user: departed_actor).find_each(&:discard!)

    expect_owner_state!
    expect do
      described_class.new(departed_import).process
    end.to raise_error(StandardError)

    expect(departed_import.reload).to have_attributes(status: "failed", failed_rows: 0, imported_rows: 0)
    expect(owned_entries(user_id: departed_paul.id, include_discarded: true)).to be_empty
  end
end

# committed_data: the live Timekeeping app reads the company, users and project
# over its own database connection, so they must be committed to be seen.
RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true, forwards_to_timekeeping: true do
  let(:fwd_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:fwd_actor) { create(:user, current_workspace_id: fwd_company.id) }
  let(:fwd_paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul.fwd@example.com", current_workspace_id: fwd_company.id) }
  let(:fwd_project) { create(:project, name: "Website", billable: true, client: create(:client, company: fwd_company, name: "Acme LLC")) }
  let(:fwd_import) { create(:data_import, company: fwd_company, user: fwd_actor, options: {}) }
  let(:fwd_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_forwarded_timekeeping_env { example.run }
  end

  before do
    create(:employment, company: fwd_company, user: fwd_actor)
    fwd_actor.add_role :admin, fwd_company
    create(:employment, company: fwd_company, user: fwd_paul)
    fwd_paul.add_role :employee, fwd_company
    arrange_forwarded_timekeeping(fwd_fake, company: fwd_company,
                                            users: { fwd_actor => "admin", fwd_paul => "employee" },
                                            project: fwd_project)
    fwd_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?,Notes
      2026-01-05,Acme LLC,Website,1.5,Paul,Connors,Yes,No,first row
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes,No,second row
    CSV
  end

  # "Forwarded writes use an `Idempotency-Key` built from the data import id and a digest of the row, so rerunning a failed import does not duplicate rows it already forwarded."
  it "a forwarded rerun after a mid-import generation change resends each row's own Idempotency-Key and leaves one Timekeeping entry per row" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(generation: 3)
        admit_forwarded_generation(fwd_fake, 3)
      end
      result
    end

    expect_owner_state!("timekeeping")
    expect { described_class.new(fwd_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    first_run_keys = forwarded_create_requests(fwd_fake).pluck(:idempotency_key)
    expect(first_run_keys.size).to eq(1)

    described_class.new(fwd_import.reload).process

    posts = forwarded_create_requests(fwd_fake)
    keys_by_note = posts.group_by { |request| request[:body]["note"] }
      .transform_values { |requests| requests.pluck(:idempotency_key).uniq }
    expect(keys_by_note.keys).to contain_exactly("first row", "second row")
    expect(keys_by_note["first row"]).to eq(first_run_keys)
    expect(keys_by_note["second row"].size).to eq(1)
    expect(keys_by_note["second row"]).not_to eq(keys_by_note["first row"])

    # Grouping by note hides how many creates the rerun sent and in what order, so check its own creates too.
    rerun_posts = posts.drop(first_run_keys.size)
    rerun_keys = rerun_posts.pluck(:idempotency_key)
    expect(rerun_keys.size).to eq(2)
    expect(rerun_keys.uniq.size).to eq(2)
    expect(rerun_keys.first).to eq(first_run_keys.first)
    expect(rerun_posts.map { |request| request[:body]["note"] }).to eq(["first row", "second row"])

    expect(forwarded_stored_entry_count(fwd_fake, company: fwd_company)).to eq(2)
    expect(fwd_import.reload).to have_attributes(status: "completed", failed_rows: 0)
  end

  # The file has no Currency column, so the row's currency falls back to the company's base currency.
  it "keeps a forwarded row's Idempotency-Key when the company's base currency changes before a rerun" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(generation: 3)
        admit_forwarded_generation(fwd_fake, 3)
      end
      result
    end

    expect_owner_state!("timekeeping")
    expect { described_class.new(fwd_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    fwd_company.update!(base_currency: "USD")
    described_class.new(DataImport.find(fwd_import.id)).process

    first_row_keys = forwarded_timekeeping_requests(fwd_fake)
      .filter_map { |request| request[:idempotency_key] if request[:body]&.dig("note") == "first row" }
    expect(first_row_keys.size).to eq(2)
    expect(first_row_keys.uniq.size).to eq(1)
    expect(forwarded_stored_entry_count(fwd_fake, company: fwd_company)).to eq(2)
  end

  it "sends only the unwritten row on a rerun once the written row has reached the local projection" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(generation: 3)
        admit_forwarded_generation(fwd_fake, 3)
      end
      result
    end

    expect_owner_state!("timekeeping")
    expect { described_class.new(fwd_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    # The local copy of the forwarded first row, as snapshot delivery would
    # store it: a projection write, not a write to the owning store.
    create(:timesheet_entry, project: fwd_project, user: fwd_paul, work_date: Date.new(2026, 1, 5), duration: 90,
                             note: "first row", bill_status: "unbilled", source: "import")
    described_class.new(fwd_import.reload).process

    posted_notes = forwarded_create_requests(fwd_fake).map { |request| request[:body]["note"] }
    expect(posted_notes).to eq(["first row", "second row"])
    expect(forwarded_stored_entry_count(fwd_fake, company: fwd_company)).to eq(2)
    expect(fwd_import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end

  it "skips a forwarded row on a rerun when the run stopped right after Timekeeping stored it" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      result = original.call(*args, **kwargs)
      # Timekeeping stored the entry; the run stops before anything else happens.
      raise IOError, "worker stopped" if calls == 1

      result
    end

    expect_owner_state!("timekeeping")
    expect { described_class.new(fwd_import).process }.to raise_error(IOError)
    # The local copy of the forwarded first row, as snapshot delivery would
    # store it: a projection write, not a write to the owning store.
    create(:timesheet_entry, project: fwd_project, user: fwd_paul, work_date: Date.new(2026, 1, 5), duration: 90,
                             note: "first row", bill_status: "unbilled", source: "import")
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    described_class.new(fwd_import.reload).process

    posted_notes = forwarded_create_requests(fwd_fake).map { |request| request[:body]["note"] }
    expect(posted_notes).to eq(["first row", "second row"])
    expect(forwarded_stored_entry_count(fwd_fake, company: fwd_company)).to eq(2)
    expect(fwd_import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  include HarvestImporterSpecRelay

  let(:fold_gen_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:fold_gen_actor) { create(:user, current_workspace_id: fold_gen_company.id) }
  let(:fold_gen_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "fold-gen-paul@example.com",
                  current_workspace_id: fold_gen_company.id)
  end
  let(:fold_gen_import) { create(:data_import, company: fold_gen_company, user: fold_gen_actor, options: {}) }

  before do
    create(:employment, company: fold_gen_company, user: fold_gen_actor)
    fold_gen_actor.add_role :admin, fold_gen_company
    create(:employment, company: fold_gen_company, user: fold_gen_paul)
    create(:project, name: "Website", billable: true, client: create(:client, company: fold_gen_company, name: "Acme LLC"))
    fold_gen_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,No,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,No,same work
    CSV
  end

  # "A generation change or handoff partway through an import fails the job visibly and is not counted as a failed or skipped row"
  it "a legacy import of two identical rows whose generation changes after the first row fails, counts nothing failed or skipped, stores one entry for the user, and a rerun writes only the second identical row" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        # Delivered before the change: the projection refuses an earlier generation's snapshot after it.
        relay_local_entries_to_projection(fold_gen_company)
        ownership = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
        ownership.increment!(:generation)
        # The live app admits writes at its own generation, so it moves with the
        # monolith's; this group has no fake, and nothing else reads the argument then.
        admit_forwarded_generation(nil, ownership.generation) if TimekeepingRegressionAdapter.current
      end
      result
    end

    expect_owner_state!
    expect { described_class.new(fold_gen_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)

    # Counts every entry for the user, not only the matching note, so a stray extra write also fails.
    expect(owned_entries(user_id: fold_gen_paul.id, include_discarded: true).size).to eq(1)
    expect(owned_entries(user_id: fold_gen_paul.id, note: "same work", include_discarded: true).size).to eq(1)
    expect(fold_gen_import.reload).to have_attributes(status: "failed", imported_rows: 1, failed_rows: 0, skipped_rows: 0)
    expect(fold_gen_import.row_errors).to eq([])

    run_harvest_import(fold_gen_import.reload)

    # Both identical rows end up stored once each: the rerun skips the row already written and writes the other.
    expect(owned_entries(user_id: fold_gen_paul.id, note: "same work", source: "import", include_discarded: true).size)
      .to eq(2)
    expect(fold_gen_import.reload).to have_attributes(status: "completed", failed_rows: 0)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true, forwards_to_timekeeping: true do
  let(:billed_fwd_company) { create(:company) }
  let(:billed_fwd_actor) { create(:user, current_workspace_id: billed_fwd_company.id) }
  let(:billed_fwd_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "billed-fwd-paul@example.com",
                  current_workspace_id: billed_fwd_company.id)
  end
  let(:billed_fwd_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: billed_fwd_company, name: "Acme LLC"))
  end
  let(:billed_fwd_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:billed_fwd_import) { create(:data_import, company: billed_fwd_company, user: billed_fwd_actor) }

  before do
    create(:employment, company: billed_fwd_company, user: billed_fwd_actor)
    billed_fwd_actor.add_role :admin, billed_fwd_company
    create(:employment, company: billed_fwd_company, user: billed_fwd_paul)
    arrange_forwarded_timekeeping(billed_fwd_fake, company: billed_fwd_company,
                                                   users: { billed_fwd_actor => "admin", billed_fwd_paul => "employee" },
                                                   project: billed_fwd_project)
    billed_fwd_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes,Yes
    CSV
  end

  # "Forwarded, it is one create with `bill_status: "billed"`."
  it "forwards a billed Harvest row as exactly one create carrying billed" do
    expect_owner_state!("timekeeping")
    with_forwarded_timekeeping_env { described_class.new(billed_fwd_import).process }

    sent = forwarded_timekeeping_requests(billed_fwd_fake)
    expect(sent.pluck(:method)).to eq(["POST"])
    expect(sent.first[:body]["bill_status"]).to eq("billed")
    expect(billed_fwd_import.reload).to have_attributes(status: "completed", imported_rows: 1, failed_rows: 0)
    expect(billed_fwd_import.row_errors).to eq([])
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:legacy_billed_company) { create(:company) }
  let(:legacy_billed_actor) { create(:user, current_workspace_id: legacy_billed_company.id) }
  let(:legacy_billed_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "legacy-billed-paul@example.com",
                  current_workspace_id: legacy_billed_company.id)
  end
  let(:legacy_billed_import) { create(:data_import, company: legacy_billed_company, user: legacy_billed_actor) }

  before do
    create(:employment, company: legacy_billed_company, user: legacy_billed_actor)
    create(:employment, company: legacy_billed_company, user: legacy_billed_paul)
    legacy_billed_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes,Yes
    CSV
  end

  # "On the legacy branch, today's `TimesheetEntry.create!` then `entry.update!(bill_status: :billed)` run inside one gateway call and one transaction."
  it "leaves no unbilled entry when the legacy billing step of a billed row is refused", writes_legacy_store: true do
    allow_any_instance_of(TimesheetEntry).to receive(:update!).and_wrap_original do |original, *_args, **_kwargs|
      original.receiver.errors.add(:base, "billing refused")
      raise ActiveRecord::RecordInvalid.new(original.receiver)
    end

    expect_owner_state!
    described_class.new(legacy_billed_import).process

    expect(TimesheetEntry.where(user: legacy_billed_paul)).not_to exist
    expect(legacy_billed_import.reload).to have_attributes(status: "completed", imported_rows: 0, failed_rows: 1)
    expect(legacy_billed_import.row_errors.size).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  include HarvestImporterSpecRelay

  let(:company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:actor) { create(:user, current_workspace_id: company.id) }
  let(:paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: company.id) }
  let(:jane) { create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: company.id) }
  let(:data_import) { create(:data_import, company:, user: actor, options: {}) }

  before do
    create(:employment, company:, user: actor)
    actor.add_role :admin, company
    create(:employment, company:, user: paul)
    create(:employment, company:, user: jane)
    File.open(Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv")) do |file|
      data_import.file.attach(io: file, filename: "harvest.csv", content_type: "text/csv")
    end
  end

  it "keeps the import source and the billed status on legacy entries written through the gateway" do
    # "The Harvest import writer goes through Timekeeping::Gateway"
    import_calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      import_calls += 1
      original.call(*args, **kwargs)
    end

    expect_owner_state!
    run_harvest_import(data_import)

    expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 11, failed_rows: 0)
    expect(import_calls).to eq(11)

    website = company.projects.kept.find_by!(name: "Website")
    entries = owned_entries(company:)
    expect(entries.size).to eq(11)
    expect(entries.pluck("source").uniq).to eq(["import"])
    expect(entries.map { |entry| entry["source_metadata"]["tool"] }.uniq).to eq(["harvest"])
    # "A billed row is always one write that carries its final bill status, so no refusal can leave it unbilled."
    billed_rows = owned_entries(project_id: website.id, duration: 1523)
    expect(billed_rows.size).to eq(1)
    expect(billed_rows.fetch(0)).to include("bill_status" => "billed")
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  let(:stale_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:stale_actor) { create(:user, current_workspace_id: stale_company.id) }
  let(:stale_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: stale_company.id)
  end
  let(:stale_jane) do
    create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: stale_company.id)
  end
  let(:stale_import) { create(:data_import, company: stale_company, user: stale_actor, options: {}) }

  before do
    [stale_actor, stale_paul, stale_jane].each { |user| create(:employment, company: stale_company, user:) }
    stale_actor.add_role :admin, stale_company
    File.open(Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv")) do |file|
      stale_import.file.attach(io: file, filename: "harvest.csv", content_type: "text/csv")
    end
  end

  # "A generation change or handoff partway through an import fails the job visibly and is not counted as a failed or skipped row"
  # The generation is bumped after the first row is written, so an importer that re-reads the
  # generation per row, or rescues the refusal as a row error, keeps going and this test fails.
  it "fails the import when the generation changes after the first row, without counting the refused row as failed or skipped" do
    writes = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      writes += 1
      if writes == 1
        # Delivered before the change: the projection refuses an earlier generation's snapshot after it.
        relay_local_entries_to_projection(stale_company)
        ownership = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
        ownership.update_columns(generation: ownership.generation + 1)
      end
      result
    end

    expect_owner_state!
    expect { described_class.new(stale_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)

    expect(stale_import.reload).to have_attributes(status: "failed", failed_rows: 0, skipped_rows: 1, imported_rows: 1)
    expect(stale_import.row_errors).to be_empty
    expect(owned_entries(company: stale_company, include_discarded: true).size).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  let(:fold_handoff_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:fold_handoff_actor) { create(:user, current_workspace_id: fold_handoff_company.id) }
  let(:fold_handoff_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: fold_handoff_company.id)
  end
  let(:fold_handoff_jane) do
    create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: fold_handoff_company.id)
  end
  let(:fold_handoff_import) { create(:data_import, company: fold_handoff_company, user: fold_handoff_actor, options: {}) }

  before do
    [fold_handoff_actor, fold_handoff_paul, fold_handoff_jane].each { |user| create(:employment, company: fold_handoff_company, user:) }
    fold_handoff_actor.add_role :admin, fold_handoff_company
    File.open(Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv")) do |file|
      fold_handoff_import.file.attach(io: file, filename: "harvest.csv", content_type: "text/csv")
    end
  end

  # "A generation change or handoff partway through an import fails the job visibly and is not counted as a failed or skipped row"
  it "a handoff after the first row of the detailed Harvest file raises OwnershipMoving, counts nothing failed, and stores one entry for the company" do
    writes = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      writes += 1
      if writes == 1
        # Delivered before the handoff starts, as the drain would deliver it.
        relay_local_entries_to_projection(fold_handoff_company)
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(handoff_step: "close_admission")
      end
      result
    end

    expect_owner_state!
    expect { described_class.new(fold_handoff_import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)

    expect(fold_handoff_import.reload).to have_attributes(status: "failed", failed_rows: 0, skipped_rows: 1, imported_rows: 1)
    expect(fold_handoff_import.row_errors).to be_empty
    expect(owned_entries(company: fold_handoff_company, include_discarded: true).size).to eq(1)
    expect(writes).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true, forwards_to_timekeeping: true do
  let(:rerun_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:rerun_actor) { create(:user, current_workspace_id: rerun_company.id) }
  let(:rerun_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: rerun_company.id)
  end
  let(:rerun_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: rerun_company, name: "Acme LLC"))
  end
  let(:rerun_import) { create(:data_import, company: rerun_company, user: rerun_actor, options: {}) }
  let(:rerun_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  before do
    create(:employment, company: rerun_company, user: rerun_actor)
    create(:employment, company: rerun_company, user: rerun_paul)
    rerun_actor.add_role :admin, rerun_company
    arrange_forwarded_timekeeping(rerun_fake, company: rerun_company,
                                              users: { rerun_actor => "admin", rerun_paul => "employee" },
                                              project: rerun_project)
    # Two identical Harvest rows: the importer keeps them as two entries, told apart by line number.
    rerun_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes
    CSV
  end

  def rerun_create_keys
    forwarded_create_requests(rerun_fake).pluck(:idempotency_key)
  end

  # "Forwarded writes use an `Idempotency-Key` built from the data import id and a digest of the row, so rerunning a failed import does not duplicate rows it already forwarded."
  it "reruns a forwarded import that failed partway with the same Idempotency-Key per row and a different key for an identical row" do
    fail_second_write = true
    writes = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      writes += 1
      raise Timekeeping::EntryWriteClient::Error, "Timekeeping unavailable" if fail_second_write && writes == 2

      original.call(*args, **kwargs)
    end

    expect_owner_state!("timekeeping")
    with_forwarded_timekeeping_env do
      expect { described_class.new(rerun_import).process }.to raise_error(Timekeeping::EntryWriteClient::Error)
    end
    first_run_keys = rerun_create_keys
    expect(rerun_import.reload).to have_attributes(status: "failed", failed_rows: 0)

    fail_second_write = false
    with_forwarded_timekeeping_env { described_class.new(rerun_import).process }
    rerun_keys = rerun_create_keys.drop(first_run_keys.size)

    expect(first_run_keys.size).to eq(1)
    expect(rerun_keys.size).to eq(2)
    expect(rerun_keys.first).to eq(first_run_keys.first)
    expect(rerun_keys.uniq.size).to eq(2)
    expect(rerun_import.reload).to have_attributes(status: "completed", imported_rows: 2, failed_rows: 0)
  end

  it "keeps an earlier write's record through a refused retry, so the identical row is written once the local copy arrives" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(generation: 3)
        admit_forwarded_generation(rerun_fake, 3)
      end
      result
    end
    expect_owner_state!("timekeeping")
    with_forwarded_timekeeping_env do
      expect { described_class.new(rerun_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    end
    expect(rerun_import.reload.attempted_rows).to include(2)

    # A handoff refuses the retry before the first row's local copy has arrived.
    ownership = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
    ownership.update_columns(handoff_step: "close_admission")
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    with_forwarded_timekeeping_env do
      expect { described_class.new(rerun_import.reload).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    end
    expect(rerun_import.reload.attempted_rows).to include(2)

    ownership.update_columns(handoff_step: nil)
    # The local copy of the forwarded first row, as snapshot delivery would
    # store it: a projection write, not a write to the owning store.
    create(:timesheet_entry, project: rerun_project, user: rerun_paul, work_date: Date.new(2026, 1, 5), duration: 60,
                             note: "", bill_status: "unbilled", source: "import")
    with_forwarded_timekeeping_env { described_class.new(rerun_import.reload).process }

    expect(forwarded_stored_entry_count(rerun_fake, company: rerun_company)).to eq(2)
    expect(rerun_import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  let(:fresh_dup_company) { create(:company) }
  let(:fresh_dup_actor) { create(:user, current_workspace_id: fresh_dup_company.id) }
  let(:fresh_dup_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "fresh-dup-paul@example.com",
                  current_workspace_id: fresh_dup_company.id)
  end
  let(:fresh_dup_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: fresh_dup_company, name: "Acme LLC"))
  end
  let(:fresh_dup_import) { create(:data_import, company: fresh_dup_company, user: fresh_dup_actor) }

  before do
    create(:employment, company: fresh_dup_company, user: fresh_dup_actor)
    create(:employment, company: fresh_dup_company, user: fresh_dup_paul)
    # A projection write: it stands in for the matching entry an earlier import
    # stored, which the importer finds in timesheet_entries.
    create(:timesheet_entry, project: fresh_dup_project, user: fresh_dup_paul, work_date: Date.new(2026, 1, 5),
                             duration: 60, note: "same work", bill_status: "unbilled", source: "import")
    fresh_dup_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
    CSV
  end

  it "skips every identical row of a fresh import when one matching entry is already stored" do
    # The matching entry above is a projection row, which the owning store
    # holds only in the legacy state, so the check is that the owner gains none.
    expect_owner_state!
    expect do
      described_class.new(fresh_dup_import).process
    end.not_to change { owned_entries(user_id: fresh_dup_paul.id, note: "same work", include_discarded: true).size }
    # The projection row itself is still the one match, in every state.
    expect(TimesheetEntry.where(user: fresh_dup_paul, note: "same work").count).to eq(1)
    expect(fresh_dup_import.reload).to have_attributes(status: "completed", imported_rows: 0, skipped_rows: 2)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true, forwards_to_timekeeping: true do
  let(:drift_company) { create(:company) }
  let(:drift_actor) { create(:user, current_workspace_id: drift_company.id) }
  let(:drift_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "drift-paul@example.com",
                  current_workspace_id: drift_company.id)
  end
  let(:drift_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: drift_company, name: "Acme LLC"))
  end
  let(:drift_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:drift_import) { create(:data_import, company: drift_company, user: drift_actor) }

  before do
    create(:employment, company: drift_company, user: drift_actor)
    drift_actor.add_role :admin, drift_company
    create(:employment, company: drift_company, user: drift_paul)
    arrange_forwarded_timekeeping(drift_fake, company: drift_company,
                                              users: { drift_actor => "admin", drift_paul => "employee" },
                                              project: drift_project)
    drift_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes
    CSV
  end

  it "keeps a row's key when the project turns non-billable before a rerun, so Timekeeping refuses it instead of storing it twice" do
    writes = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      writes += 1
      raise Timekeeping::EntryWriteClient::Error, "Timekeeping unavailable" if writes == 2

      original.call(*args, **kwargs)
    end

    expect_owner_state!("timekeeping")
    with_forwarded_timekeeping_env do
      expect { described_class.new(drift_import).process }.to raise_error(Timekeeping::EntryWriteClient::Error)
    end
    first_key = forwarded_create_requests(drift_fake).first[:idempotency_key]

    drift_project.update!(billable: false)
    with_forwarded_timekeeping_env do
      expect { described_class.new(drift_import.reload).process }.to raise_error(Timekeeping::EntryWriteClient::Rejected)
    end

    expect(forwarded_create_requests(drift_fake).pluck(:idempotency_key)).to eq([first_key, first_key])
    expect(forwarded_stored_entry_count(drift_fake, company: drift_company)).to eq(1)
    expect(drift_import.reload).to have_attributes(status: "failed", failed_rows: 0)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter, committed_data: true do
  let(:rerun_dup_company) { create(:company) }
  let(:rerun_dup_actor) { create(:user, current_workspace_id: rerun_dup_company.id) }
  let(:rerun_dup_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "rerun-dup-paul@example.com",
                  current_workspace_id: rerun_dup_company.id)
  end
  let(:rerun_dup_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: rerun_dup_company, name: "Acme LLC"))
  end

  include HarvestImporterSpecRelay

  before do
    create(:employment, company: rerun_dup_company, user: rerun_dup_actor)
    rerun_dup_actor.add_role :admin, rerun_dup_company
    create(:employment, company: rerun_dup_company, user: rerun_dup_paul)
    rerun_dup_project
  end

  def rerun_dup_import_with(csv)
    create(:data_import, company: rerun_dup_company, user: rerun_dup_actor).tap do |import|
      import.file.attach(io: StringIO.new(csv), filename: "harvest.csv", content_type: "text/csv")
    end
  end

  def rerun_dup_refuse_import_call(number)
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise Timekeeping::Gateway::OwnershipMoving if calls == number

      original.call(*args, **kwargs)
    end
  end

  def rerun_dup_entries(note)
    owned_entries(user_id: rerun_dup_paul.id, note:, source: "import", include_discarded: true).size
  end

  it "writes a skipped identical row on the third run when the second run failed before writing anything" do
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
    CSV

    rerun_dup_refuse_import_call(2)
    expect_owner_state!
    expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    relay_local_entries_to_projection(rerun_dup_company)
    expect(rerun_dup_entries("same work")).to eq(1)

    rerun_dup_refuse_import_call(1)
    expect { described_class.new(import.reload).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    expect(import.reload).to have_attributes(status: "failed", imported_rows: 0)

    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    run_harvest_import(import.reload)

    expect(rerun_dup_entries("same work")).to eq(2)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end

  it "keeps skipping rows an earlier import already stored when a failed import is rerun" do
    # A projection write: it stands in for the entry the earlier import
    # stored, which the owning store holds only in the legacy state.
    create(:timesheet_entry, project: rerun_dup_project, user: rerun_dup_paul, work_date: Date.new(2026, 1, 5),
                             duration: 60, note: "earlier", bill_status: "unbilled", source: "import")
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,earlier
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,earlier
      2026-01-06,Acme LLC,Website,1,Paul,Connors,Yes,second
      2026-01-07,Acme LLC,Website,1,Paul,Connors,Yes,third
    CSV
    earlier_entries = rerun_dup_entries("earlier")

    rerun_dup_refuse_import_call(2)
    expect_owner_state!
    expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    relay_local_entries_to_projection(rerun_dup_company)
    expect(rerun_dup_entries("second")).to eq(1)

    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    run_harvest_import(import.reload)

    expect(rerun_dup_entries("earlier")).to eq(earlier_entries)
    # The projection row itself is still the one match, in every state.
    expect(TimesheetEntry.where(user: rerun_dup_paul, note: "earlier", source: "import").count).to eq(1)
    expect(rerun_dup_entries("second")).to eq(1)
    expect(rerun_dup_entries("third")).to eq(1)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 3)
  end

  it "writes the second identical row on a rerun when the run stopped right after the first row was written" do
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
    CSV
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      result = original.call(*args, **kwargs)
      # The entry is committed; the run stops before anything else happens.
      raise IOError, "worker stopped" if calls == 1

      result
    end

    expect_owner_state!
    expect { described_class.new(import).process }.to raise_error(IOError)
    relay_local_entries_to_projection(rerun_dup_company)
    expect(rerun_dup_entries("same work")).to eq(1)

    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    run_harvest_import(import.reload)

    expect(rerun_dup_entries("same work")).to eq(2)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end

  it "skips both identical rows on a rerun when the first was refused and another import then stored a match" do
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
    CSV

    rerun_dup_refuse_import_call(1)
    expect_owner_state!
    expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    expect(rerun_dup_entries("same work")).to eq(0)
    expect(import.reload.attempted_rows).to be_empty

    # A projection write: it stands in for the match another import stored,
    # which the owning store holds only in the legacy state, so the check
    # below is that the rerun adds no entry to the owner.
    create(:timesheet_entry, project: rerun_dup_project, user: rerun_dup_paul, work_date: Date.new(2026, 1, 5),
                             duration: 60, note: "same work", bill_status: "unbilled", source: "import")
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    expect do
      described_class.new(import.reload).process
    end.not_to change { rerun_dup_entries("same work") }
    # The projection row itself is still the one match, in every state.
    expect(TimesheetEntry.where(user: rerun_dup_paul, note: "same work", source: "import").count).to eq(1)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 0, skipped_rows: 2)
  end

  it "skips every matching row of an upload queued before an earlier upload stored its entry" do
    first_import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,queued
    CSV
    second_import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,queued
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,queued
    CSV

    expect_owner_state!
    run_harvest_import(first_import)
    run_harvest_import(second_import)

    expect(rerun_dup_entries("queued")).to eq(1)
    expect(second_import.reload).to have_attributes(status: "completed", imported_rows: 0, skipped_rows: 2)
  end

  it "keeps the row errors met before an ownership refusal stops the import" do
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,100001,Paul,Connors,Yes,too long
      2026-01-06,Acme LLC,Website,1,Paul,Connors,Yes,refused
    CSV

    rerun_dup_refuse_import_call(2)
    expect_owner_state!
    expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)

    expect(import.reload).to have_attributes(status: "failed", imported_rows: 0, failed_rows: 1, skipped_rows: 0)
    expect(import.row_errors.pluck("row")).to eq([2])
  end

  it "writes the valid rows on both sides of a row the model rejects" do
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,before
      2026-01-06,Acme LLC,Website,100001,Paul,Connors,Yes,rejected
      2026-01-07,Acme LLC,Website,1,Paul,Connors,Yes,after
    CSV

    expect_owner_state!
    run_harvest_import(import)

    expect(rerun_dup_entries("before")).to eq(1)
    expect(rerun_dup_entries("after")).to eq(1)
    expect(rerun_dup_entries("rejected")).to eq(0)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 2, failed_rows: 1)
    expect(import.row_errors.pluck("row")).to eq([3])
  end
end

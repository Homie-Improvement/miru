# frozen_string_literal: true

require "rails_helper"

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:actor) { create(:user, current_workspace_id: company.id) }
  let(:paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: company.id) }
  let(:jane) { create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: company.id) }
  let(:data_import) { create(:data_import, company:, user: actor, options:) }
  let(:options) { {} }
  let(:fixture_path) { Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv") }

  before do
    create(:employment, company:, user: actor)
    create(:employment, company:, user: paul)
    create(:employment, company:, user: jane)
    attach_csv(data_import, fixture_path)
  end

  it "creates clients, projects, members, and entries with Harvest values" do
    described_class.new(data_import).process

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
    expect(website.timesheet_entries.kept.where(note: "Meeting - Daily sync").count).to eq(2)

    first_entry = website.timesheet_entries.kept.find_by!(note: "Programming - Built landing\nand tests")
    expect(first_entry).to have_attributes(duration: 75, bill_status: "unbilled", source: "import")
    expect(first_entry.source_metadata).to eq("tool" => "harvest")
    expect(website.timesheet_entries.kept.find_by!(duration: 1523)).to be_billed
    internal = company.projects.kept.find_by!(name: "Internal")
    expect(internal).not_to be_billable
    expect(internal.timesheet_entries.kept).to all(be_non_billable)
    expect(company.clients.kept.find_by!(name: "Very Long Client Name T-715152").currency).to eq("USD")
    expect(website.project_members.kept.find_by!(user: paul).hourly_rate).to eq(150)
  end

  it "tags imported records with the import source and reports completion" do
    Rails.event.set_context(source: "cli")
    entry_event = nil
    completed = assert_event_reported("Imports::Completed") do
      entry_event = assert_event_reported("TimesheetEntries::Created") { described_class.new(data_import).process }
    end

    expect(entry_event[:context]).to include(source: "harvest_import", data_import_id: data_import.id.to_s)
    expect(completed[:payload].to_h).to include(actor: { id: actor.id, type: "User" })
    expect(completed[:payload].to_h[:data]).to include(id: data_import.id, imported_rows: 11)
    expect(RailsEventViewer.events.with_context(:data_import_id, data_import.id.to_s).count).to be_positive

    following_event = assert_event_reported("after_import") { Rails.event.notify("after_import") }
    expect(following_event[:context]).to eq(source: "cli")
  end

  it "avoids per-row project membership and company queries" do
    select_queries = 0
    project_member_queries = 0
    company_queries = 0
    subscriber = lambda do |*, payload|
      sql = payload[:sql]
      next unless sql.start_with?("SELECT")

      select_queries += 1
      project_member_queries += 1 if sql.include?('FROM "project_members"')
      company_queries += 1 if sql.include?('FROM "companies"')
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.new(data_import).process
    end

    expect(select_queries).to be < 66
    expect(project_member_queries).to be < 6
    expect(company_queries).to be < 6
  end

  it "matches users by name and rounds decimal hours to minutes" do
    described_class.new(data_import).process

    advisory = company.projects.kept.find_by!(name: "Advisory")
    entry = advisory.timesheet_entries.kept.find_by!(note: "Research - Memo")
    expect(entry).to have_attributes(user: jane, duration: 80)
    expect(data_import.reload.summary.dig("users", "matched")).to include(
      "Jane Doe" => "jane@example.com",
      "Paul Connors" => "paul@example.com"
    )
  end

  context "with a user map" do
    let(:jane) { create(:user, first_name: "Janet", last_name: "Smith", email: "jane@example.com", current_workspace_id: company.id) }
    let(:options) { { "user_map" => { "Jane Doe" => "jane@example.com" } } }

    it "maps a Harvest name to a workspace email" do
      described_class.new(data_import).process

      expect(company.projects.kept.find_by!(name: "Advisory").timesheet_entries.kept.pluck(:user_id)).to all(eq(jane.id))
    end
  end

  context "with an unmatched user" do
    before { jane.employments.find_by!(company:).discard! }

    it "records an error for every unmatched row and continues" do
      described_class.new(data_import).process

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
      described_class.new(data_import).process

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
      described_class.new(data_import).process

      expect(data_import.reload.failed_rows).to eq(0)
      expect(company.projects.kept.find_by!(name: "Advisory").timesheet_entries.kept.pluck(:user_id)).to all(eq(fallback.id))
    end
  end

  context "with a dry run" do
    let(:data_import) { create(:data_import, company:, user: actor, options:, dry_run: true) }

    it "only writes import bookkeeping and reports the plan" do
      expect do
        described_class.new(data_import).process
      end.not_to change { [Client.count, Project.count, ProjectMember.count, TimesheetEntry.count] }

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

    described_class.new(data_import).process

    expect(company.clients.where("LOWER(name) = ?", "acme llc").count).to eq(1)
    expect(client.projects.where("LOWER(name) = ?", "website").count).to eq(1)
    expect(project.timesheet_entries.kept.where(user: paul)).to exist
  end

  it "parses dates using the company day-month-year format" do
    company.update!(date_format: "DD-MM-YYYY")
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      07-01-2026,Acme LLC,Website,1,Paul,Connors
    CSV

    described_class.new(data_import).process

    expect(TimesheetEntry.kept.last.work_date).to eq(Date.new(2026, 1, 7))
  end

  it "keeps project names distinct when their 30-character prefixes collide" do
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Project Code,Hours,First Name,Last Name
      2026-01-01,Acme LLC,Acme 1H 2025 Committed Hours (PC),PC,1,Paul,Connors
    CSV

    described_class.new(data_import).process

    second_import = create(:data_import, company:, user: actor)
    attach_csv_contents(second_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-02,Acme LLC,Acme 1H 2025 Committed Hours (LW),1,Paul,Connors
    CSV
    described_class.new(second_import).process

    projects = company.projects.kept.order(:name)
    expect(projects.pluck(:name).uniq.size).to eq(2)
    expect(projects.pluck(:name).map(&:length)).to all(be <= 30)
    expect(projects.pluck(:description)).to contain_exactly(
      "Harvest project: Acme 1H 2025 Committed Hours (LW)",
      "Harvest project: Acme 1H 2025 Committed Hours (PC)\nHarvest project code: PC"
    )
    expect(projects.flat_map { |project| project.timesheet_entries.kept.pluck(:work_date) }).to contain_exactly(
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
      described_class.new(reimport).process
    end.not_to change { [company.projects.kept.count, TimesheetEntry.kept.count] }
    expect(reimport.reload).to have_attributes(imported_rows: 0, skipped_rows: 2)
  end

  it "keeps client names distinct when their 30-character prefixes collide" do
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-01,Acme Corporate Legal Services Alpha,Website,1,Paul,Connors
    CSV

    described_class.new(data_import).process

    second_import = create(:data_import, company:, user: actor)
    attach_csv_contents(second_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-02,Acme Corporate Legal Services Bravo,Website,1,Paul,Connors
    CSV
    described_class.new(second_import).process

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
    create(:timesheet_entry, project: legacy_project, user: paul, work_date: Date.new(2026, 1, 1), duration: 60, note: "", source: "import")
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-01,#{client_name},#{project_name},1,Paul,Connors
    CSV

    expect do
      described_class.new(data_import).process
    end.not_to change { [company.clients.count, company.projects.count, TimesheetEntry.count] }

    expect(data_import.reload).to have_attributes(imported_rows: 0, skipped_rows: 1)
  end

  it "records invalid hours, date, and blank client rows without creating entries" do
    attach_csv_contents(data_import, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-01,Acme LLC,Website,abc,Paul,Connors
      31-31-2026,Acme LLC,Website,1,Paul,Connors
      2026-01-03,,Website,1,Paul,Connors
    CSV

    expect do
      described_class.new(data_import).process
    end.not_to change(TimesheetEntry, :count)

    expect(data_import.reload.row_errors).to eq([
      { "row" => 2, "message" => "Hours is invalid" },
      { "row" => 3, "message" => "Date is invalid: 31-31-2026" },
      { "row" => 4, "message" => "Client is blank" }
    ])
  end

  it "skips entries already imported without de-duplicating rows within the file" do
    described_class.new(data_import).process
    second_import = create(:data_import, company:, user: actor)
    attach_csv(second_import, fixture_path)

    expect do
      described_class.new(second_import).process
    end.not_to change(TimesheetEntry, :count)

    expect(second_import.reload).to have_attributes(imported_rows: 0, skipped_rows: 12)
    expect(second_import.summary["duplicates_skipped"]).to eq(11)
    expect(second_import.summary["date_range"]).to eq("from" => "2026-01-02", "to" => "2026-01-11")
  end

  it "rejects files missing required headers" do
    invalid_import = create(:data_import, company:, user: actor)
    invalid_import.file.attach(io: StringIO.new("Date,Client\n2026-01-01,Acme\n"), filename: "invalid.csv", content_type: "text/csv")

    expect do
      described_class.new(invalid_import).process
    end.to raise_error(described_class::InvalidFileError, /Missing required headers: Project, Hours, First Name, Last Name/)
  end

  it "reports client name truncation" do
    described_class.new(data_import).process

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

    described_class.new(data_import).process

    project = client.projects.find_by!(name: "A Project Name Longer T-ae2f52")
    expect(project.timesheet_entries.kept).to exist
    expect(data_import.reload.summary["warnings"]).to include(
      "Project name truncated: A Project Name Longer Than Thirty Characters"
    )

    reimport = create(:data_import, company:, user: actor)
    attach_csv_contents(reimport, <<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-01,Acme LLC,A PROJECT NAME LONGER THAN THIRTY CHARACTERS,1,Paul,Connors,Yes
    CSV

    expect do
      described_class.new(reimport).process
    end.not_to change { [client.projects.count, TimesheetEntry.kept.count] }
  end

  it "restores an archived client before importing entries" do
    client = create(:client, company:, name: "Acme LLC")
    client.discard!

    described_class.new(data_import).process

    expect(client.reload).to be_kept
    expect(client.projects.kept.find_by!(name: "Website").timesheet_entries.kept).to exist
    expect(data_import.reload.summary["warnings"]).to include("Restored archived client: Acme LLC")
  end

  it "restores an archived project before importing entries" do
    client = create(:client, company:, name: "Acme LLC")
    project = create(:project, client:, name: "Website", billable: true)
    project.discard!

    described_class.new(data_import).process

    expect(project.reload).to be_kept
    expect(project.timesheet_entries.kept).to exist
    expect(data_import.reload.summary["warnings"]).to include("Restored archived project: Acme LLC / Website")
  end

  it "schedules the uploaded CSV for purge after a real run" do
    expect do
      described_class.new(data_import).process
    end.to have_enqueued_job(ActiveStorage::PurgeJob).with(data_import.file.blob)
  end

  it "keeps an existing non-billable project non-billable and warns once" do
    client = create(:client, company:, name: "Acme LLC")
    project = create(:project, client:, name: "Website", billable: false)

    described_class.new(data_import).process

    expect(project.timesheet_entries.kept).to all(be_non_billable)
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
end

# Generated by Descant: acceptance tests below.
RSpec.describe Imports::HarvestTimeEntriesImporter do
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

    expect do
      described_class.new(departed_import).process
    end.to raise_error(StandardError)

    expect(departed_import.reload).to have_attributes(status: "failed", failed_rows: 0, imported_rows: 0)
    expect(TimesheetEntry.where(user: departed_paul)).not_to exist
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:fwd_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:fwd_actor) { create(:user, current_workspace_id: fwd_company.id) }
  let(:fwd_paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul.fwd@example.com", current_workspace_id: fwd_company.id) }
  let(:fwd_project) { create(:project, name: "Website", billable: true, client: create(:client, company: fwd_company, name: "Acme LLC")) }
  let(:fwd_import) { create(:data_import, company: fwd_company, user: fwd_actor, options: {}) }
  let(:fwd_base_url) { "http://timekeeping.test" }
  let(:fwd_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  around do |example|
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, fwd_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) { example.run }
    end
  end

  before do
    create(:employment, company: fwd_company, user: fwd_actor)
    fwd_actor.add_role :admin, fwd_company
    create(:employment, company: fwd_company, user: fwd_paul)
    fwd_paul.add_role :employee, fwd_company
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
    fwd_fake.generation = 2
    fwd_fake.register_company(id: fwd_company.id, edit_days: fwd_company.timesheet_edit_days)
    fwd_fake.register_user(id: fwd_actor.id, company_id: fwd_company.id, role: "admin")
    fwd_fake.register_user(id: fwd_paul.id, company_id: fwd_company.id, role: "employee")
    fwd_fake.register_project(id: fwd_project.id, company_id: fwd_company.id)
    route_timekeeping_to_fake(fwd_fake, base_url: fwd_base_url)
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
        fwd_fake.generation = 3
      end
      result
    end

    expect { described_class.new(fwd_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    first_run_keys = fwd_fake.requests
      .filter_map { |request| request[:headers]["Idempotency-Key"] if request[:method] == "POST" }
    expect(first_run_keys.size).to eq(1)

    described_class.new(fwd_import.reload).process

    posts = fwd_fake.requests.select { |request| request[:method] == "POST" }
    keys_by_note = posts.group_by { |request| request[:body]["note"] }
      .transform_values { |requests| requests.map { |request| request[:headers]["Idempotency-Key"] }.uniq }
    expect(keys_by_note.keys).to contain_exactly("first row", "second row")
    expect(keys_by_note["first row"]).to eq(first_run_keys)
    expect(keys_by_note["second row"].size).to eq(1)
    expect(keys_by_note["second row"]).not_to eq(keys_by_note["first row"])

    stored_entry_ids = fwd_fake.outbox.map { |row| row["entry"]["id"] }.uniq
    expect(stored_entry_ids.size).to eq(2)
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
        fwd_fake.generation = 3
      end
      result
    end

    expect { described_class.new(fwd_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    fwd_company.update!(base_currency: "USD")
    described_class.new(DataImport.find(fwd_import.id)).process

    first_row_keys = fwd_fake.requests
      .filter_map { |request| request[:headers]["Idempotency-Key"] if request[:body]&.dig("note") == "first row" }
    expect(first_row_keys.size).to eq(2)
    expect(first_row_keys.uniq.size).to eq(1)
    expect(fwd_fake.outbox.map { |row| row["entry"]["id"] }.uniq.size).to eq(2)
  end

  it "sends only the unwritten row on a rerun once the written row has reached the local projection" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      if calls == 1
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(generation: 3)
        fwd_fake.generation = 3
      end
      result
    end

    expect { described_class.new(fwd_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
    # The local copy of the forwarded first row, as snapshot delivery would store it.
    create(:timesheet_entry, project: fwd_project, user: fwd_paul, work_date: Date.new(2026, 1, 5), duration: 90,
                             note: "first row", bill_status: "unbilled", source: "import")
    described_class.new(fwd_import.reload).process

    posted_notes = fwd_fake.requests.filter_map { |request| request[:body]&.dig("note") if request[:method] == "POST" }
    expect(posted_notes).to eq(["first row", "second row"])
    expect(fwd_fake.outbox.map { |row| row["entry"]["id"] }.uniq.size).to eq(2)
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

    expect { described_class.new(fwd_import).process }.to raise_error(IOError)
    create(:timesheet_entry, project: fwd_project, user: fwd_paul, work_date: Date.new(2026, 1, 5), duration: 90,
                             note: "first row", bill_status: "unbilled", source: "import")
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    described_class.new(fwd_import.reload).process

    posted_notes = fwd_fake.requests.filter_map { |request| request[:body]&.dig("note") if request[:method] == "POST" }
    expect(posted_notes).to eq(["first row", "second row"])
    expect(fwd_fake.outbox.map { |row| row["entry"]["id"] }.uniq.size).to eq(2)
    expect(fwd_import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:legacy_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:legacy_actor) { create(:user, current_workspace_id: legacy_company.id) }
  let(:legacy_paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul.legacy@example.com", current_workspace_id: legacy_company.id) }
  let(:legacy_import) { create(:data_import, company: legacy_company, user: legacy_actor, options: {}) }

  before do
    create(:employment, company: legacy_company, user: legacy_actor)
    legacy_actor.add_role :admin, legacy_company
    create(:employment, company: legacy_company, user: legacy_paul)
    create(:project, name: "Website", billable: true, client: create(:client, company: legacy_company, name: "Acme LLC"))
    legacy_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,No,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,No,same work
    CSV
  end

  # "A generation change or handoff partway through an import fails the job visibly and is not counted as a failed or skipped row"
  it "a legacy import whose generation changes after its first row fails, stores one imported row, counts nothing failed or skipped, and a rerun writes only the second identical row" do
    calls = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      calls += 1
      TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).increment!(:generation) if calls == 1
      result
    end

    expect { described_class.new(legacy_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)

    expect(TimesheetEntry.where(user: legacy_paul, note: "same work").count).to eq(1)
    expect(legacy_import.reload).to have_attributes(status: "failed", imported_rows: 1, failed_rows: 0, skipped_rows: 0)
    expect(legacy_import.row_errors).to be_empty

    described_class.new(legacy_import.reload).process

    # Both identical rows end up stored once each: the rerun skips the row already written and writes the other.
    expect(TimesheetEntry.where(user: legacy_paul, note: "same work", source: "import").count).to eq(2)
    expect(legacy_import.reload).to have_attributes(status: "completed", failed_rows: 0)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:billed_fwd_company) { create(:company) }
  let(:billed_fwd_actor) { create(:user, current_workspace_id: billed_fwd_company.id) }
  let(:billed_fwd_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "billed-fwd-paul@example.com",
                  current_workspace_id: billed_fwd_company.id)
  end
  let(:billed_fwd_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: billed_fwd_company, name: "Acme LLC"))
  end
  let(:billed_fwd_base_url) { "http://timekeeping.test" }
  let(:billed_fwd_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:billed_fwd_import) { create(:data_import, company: billed_fwd_company, user: billed_fwd_actor) }

  before do
    create(:employment, company: billed_fwd_company, user: billed_fwd_actor)
    billed_fwd_actor.add_role :admin, billed_fwd_company
    create(:employment, company: billed_fwd_company, user: billed_fwd_paul)
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
    billed_fwd_fake.generation = 2
    billed_fwd_fake.register_company(id: billed_fwd_company.id, edit_days: billed_fwd_company.timesheet_edit_days)
    billed_fwd_fake.register_user(id: billed_fwd_actor.id, company_id: billed_fwd_company.id, role: "admin")
    billed_fwd_fake.register_user(id: billed_fwd_paul.id, company_id: billed_fwd_company.id, role: "employee")
    billed_fwd_fake.register_project(id: billed_fwd_project.id, company_id: billed_fwd_company.id)
    route_timekeeping_to_fake(billed_fwd_fake, base_url: billed_fwd_base_url)
    billed_fwd_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes,Yes
    CSV
  end

  # "Forwarded, it is one create with `bill_status: "billed"`."
  it "forwards a billed Harvest row as exactly one create carrying billed" do
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, billed_fwd_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) do
        described_class.new(billed_fwd_import).process
      end
    end

    expect(billed_fwd_fake.requests.pluck(:method)).to eq(["POST"])
    expect(billed_fwd_fake.requests.first[:body]["bill_status"]).to eq("billed")
    expect(billed_fwd_import.reload).to have_attributes(status: "completed", imported_rows: 1, failed_rows: 0)
    expect(billed_fwd_import.row_errors).to eq([])
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:rerun_company) { create(:company) }
  let(:rerun_actor) { create(:user, current_workspace_id: rerun_company.id) }
  let(:rerun_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "rerun-paul@example.com",
                  current_workspace_id: rerun_company.id)
  end
  let(:rerun_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: rerun_company, name: "Acme LLC"))
  end
  let(:rerun_base_url) { "http://timekeeping.test" }
  let(:rerun_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:rerun_import) { create(:data_import, company: rerun_company, user: rerun_actor) }

  before do
    create(:employment, company: rerun_company, user: rerun_actor)
    rerun_actor.add_role :admin, rerun_company
    create(:employment, company: rerun_company, user: rerun_paul)
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
    rerun_fake.generation = 2
    rerun_fake.register_company(id: rerun_company.id, edit_days: rerun_company.timesheet_edit_days)
    rerun_fake.register_user(id: rerun_actor.id, company_id: rerun_company.id, role: "admin")
    rerun_fake.register_user(id: rerun_paul.id, company_id: rerun_company.id, role: "employee")
    rerun_fake.register_project(id: rerun_project.id, company_id: rerun_company.id)
    route_timekeeping_to_fake(rerun_fake, base_url: rerun_base_url)
    rerun_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Invoiced?
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,No
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes,No
    CSV
  end

  # "Forwarded writes use an `Idempotency-Key` built from the data import id and a digest of the row, so rerunning a failed import does not duplicate rows it already forwarded."
  it "reruns a failed forwarded import with the same Idempotency-Key per row and distinct keys across rows" do
    bumped = false
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      unless bumped
        bumped = true
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(generation: 3)
        rerun_fake.generation = 3
      end
      result
    end

    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, rerun_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem) do
        expect { described_class.new(rerun_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)
        first_run_keys = rerun_fake.requests.filter_map { |r| r[:headers]["Idempotency-Key"] if r[:method] == "POST" }
        expect(first_run_keys.size).to eq(1)

        described_class.new(rerun_import.reload).process

        all_keys = rerun_fake.requests.filter_map { |r| r[:headers]["Idempotency-Key"] if r[:method] == "POST" }
        rerun_keys = all_keys.drop(first_run_keys.size)
        expect(rerun_keys.size).to eq(2)
        expect(rerun_keys.uniq.size).to eq(2)
        expect(rerun_keys.first).to eq(first_run_keys.first)
      end
    end

    expect(rerun_import.reload).to have_attributes(status: "completed", failed_rows: 0)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:gen_company) { create(:company) }
  let(:gen_actor) { create(:user, current_workspace_id: gen_company.id) }
  let(:gen_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "gen-paul@example.com", current_workspace_id: gen_company.id)
  end
  let(:gen_import) { create(:data_import, company: gen_company, user: gen_actor) }

  before do
    create(:employment, company: gen_company, user: gen_actor)
    create(:employment, company: gen_company, user: gen_paul)
    gen_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-05,Acme LLC,Website,1,Paul,Connors
      2026-01-06,Acme LLC,Website,2,Paul,Connors
    CSV
  end

  # "A generation change or handoff partway through an import fails the job visibly and is not counted as a failed or skipped row"
  it "fails the import when the generation is bumped between two rows without counting a failed row" do
    bumped = false
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      unless bumped
        bumped = true
        ownership = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
        ownership.update_columns(generation: ownership.generation + 1)
      end
      result
    end

    expect { described_class.new(gen_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)

    expect(gen_import.reload).to have_attributes(status: "failed", failed_rows: 0, skipped_rows: 0, imported_rows: 1)
    expect(gen_import.row_errors).to eq([])
    expect(TimesheetEntry.where(user: gen_paul).count).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:handoff_company) { create(:company) }
  let(:handoff_actor) { create(:user, current_workspace_id: handoff_company.id) }
  let(:handoff_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "handoff-paul@example.com",
                  current_workspace_id: handoff_company.id)
  end
  let(:handoff_import) { create(:data_import, company: handoff_company, user: handoff_actor) }

  before do
    create(:employment, company: handoff_company, user: handoff_actor)
    create(:employment, company: handoff_company, user: handoff_paul)
    handoff_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name
      2026-01-05,Acme LLC,Website,1,Paul,Connors
      2026-01-06,Acme LLC,Website,2,Paul,Connors
    CSV
  end

  # "handoff_step set partway through raises OwnershipMoving."
  it "raises OwnershipMoving when handoff_step is set partway through an import" do
    handed_off = false
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      unless handed_off
        handed_off = true
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(handoff_step: "close_admission")
      end
      result
    end

    expect { described_class.new(handoff_import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)

    expect(handoff_import.reload).to have_attributes(status: "failed", failed_rows: 0, skipped_rows: 0)
    expect(handoff_import.row_errors).to eq([])
    expect(TimesheetEntry.where(user: handoff_paul).count).to eq(1)
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
  it "leaves no unbilled entry when the legacy billing step of a billed row is refused" do
    allow_any_instance_of(TimesheetEntry).to receive(:update!).and_wrap_original do |original, *_args, **_kwargs|
      original.receiver.errors.add(:base, "billing refused")
      raise ActiveRecord::RecordInvalid.new(original.receiver)
    end

    described_class.new(legacy_billed_import).process

    expect(TimesheetEntry.where(user: legacy_billed_paul)).not_to exist
    expect(legacy_billed_import.reload).to have_attributes(status: "completed", imported_rows: 0, failed_rows: 1)
    expect(legacy_billed_import.row_errors.size).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:actor) { create(:user, current_workspace_id: company.id) }
  let(:paul) { create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: company.id) }
  let(:jane) { create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: company.id) }
  let(:data_import) { create(:data_import, company:, user: actor, options: {}) }

  before do
    create(:employment, company:, user: actor)
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

    described_class.new(data_import).process

    expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 11, failed_rows: 0)
    expect(import_calls).to eq(11)

    website = company.projects.kept.find_by!(name: "Website")
    entries = TimesheetEntry.kept.where(project_id: company.projects.select(:id))
    expect(entries.count).to eq(11)
    expect(entries.pluck(:source).uniq).to eq(["import"])
    expect(entries.map { |entry| entry.source_metadata["tool"] }.uniq).to eq(["harvest"])
    # "A billed row is always one write that carries its final bill status, so no refusal can leave it unbilled."
    expect(website.timesheet_entries.kept.where(duration: 1523).count).to eq(1)
    expect(website.timesheet_entries.kept.find_by!(duration: 1523)).to be_billed
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
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
        ownership = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID)
        ownership.update_columns(generation: ownership.generation + 1)
      end
      result
    end

    expect { described_class.new(stale_import).process }.to raise_error(Timekeeping::Gateway::StaleGeneration)

    expect(stale_import.reload).to have_attributes(status: "failed", failed_rows: 0, skipped_rows: 1, imported_rows: 1)
    expect(stale_import.row_errors).to be_empty
    expect(TimesheetEntry.joins(project: :client).where(clients: { company_id: stale_company.id }).count).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:handoff_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:handoff_actor) { create(:user, current_workspace_id: handoff_company.id) }
  let(:handoff_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: handoff_company.id)
  end
  let(:handoff_jane) do
    create(:user, first_name: "Jane", last_name: "Doe", email: "jane@example.com", current_workspace_id: handoff_company.id)
  end
  let(:handoff_import) { create(:data_import, company: handoff_company, user: handoff_actor, options: {}) }

  before do
    [handoff_actor, handoff_paul, handoff_jane].each { |user| create(:employment, company: handoff_company, user:) }
    File.open(Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv")) do |file|
      handoff_import.file.attach(io: file, filename: "harvest.csv", content_type: "text/csv")
    end
  end

  # "A generation change or handoff partway through an import fails the job visibly and is not counted as a failed or skipped row"
  it "fails the import with OwnershipMoving when a handoff starts after the first row, without counting the refused row as failed or skipped" do
    writes = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      writes += 1
      if writes == 1
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(handoff_step: "close_admission")
      end
      result
    end

    expect { described_class.new(handoff_import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)

    expect(handoff_import.reload).to have_attributes(status: "failed", failed_rows: 0, skipped_rows: 1, imported_rows: 1)
    expect(handoff_import.row_errors).to be_empty
    expect(writes).to eq(1)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:rerun_company) { create(:company, base_currency: "INR", date_format: "MM-DD-YYYY") }
  let(:rerun_actor) { create(:user, current_workspace_id: rerun_company.id) }
  let(:rerun_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "paul@example.com", current_workspace_id: rerun_company.id)
  end
  let(:rerun_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: rerun_company, name: "Acme LLC"))
  end
  let(:rerun_import) { create(:data_import, company: rerun_company, user: rerun_actor, options: {}) }
  let(:rerun_base_url) { "http://timekeeping.test" }
  let(:rerun_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }

  before do
    create(:employment, company: rerun_company, user: rerun_actor)
    create(:employment, company: rerun_company, user: rerun_paul)
    rerun_actor.add_role :admin, rerun_company
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
    rerun_fake.generation = 2
    rerun_fake.register_company(id: rerun_company.id, edit_days: rerun_company.timesheet_edit_days)
    rerun_fake.register_user(id: rerun_actor.id, company_id: rerun_company.id, role: "admin")
    rerun_fake.register_user(id: rerun_paul.id, company_id: rerun_company.id, role: "employee")
    rerun_fake.register_project(id: rerun_project.id, company_id: rerun_company.id)
    route_timekeeping_to_fake(rerun_fake, base_url: rerun_base_url)
    # Two identical Harvest rows: the importer keeps them as two entries, told apart by line number.
    rerun_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes
    CSV
  end

  def rerun_with_timekeeping(&block)
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, rerun_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem, &block)
    end
  end

  def rerun_create_keys
    rerun_fake.requests.filter_map { |request| request[:headers]["Idempotency-Key"] if request[:method] == "POST" }
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

    rerun_with_timekeeping do
      expect { described_class.new(rerun_import).process }.to raise_error(Timekeeping::EntryWriteClient::Error)
    end
    first_run_keys = rerun_create_keys
    expect(rerun_import.reload).to have_attributes(status: "failed", failed_rows: 0)

    fail_second_write = false
    rerun_with_timekeeping { described_class.new(rerun_import).process }
    rerun_keys = rerun_create_keys.drop(first_run_keys.size)

    expect(first_run_keys.size).to eq(1)
    expect(rerun_keys.size).to eq(2)
    expect(rerun_keys.first).to eq(first_run_keys.first)
    expect(rerun_keys.uniq.size).to eq(2)
    expect(rerun_import.reload).to have_attributes(status: "completed", imported_rows: 2, failed_rows: 0)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
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
    create(:timesheet_entry, project: fresh_dup_project, user: fresh_dup_paul, work_date: Date.new(2026, 1, 5),
                             duration: 60, note: "same work", bill_status: "unbilled", source: "import")
    fresh_dup_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
    CSV
  end

  it "skips every identical row of a fresh import when one matching entry is already stored" do
    described_class.new(fresh_dup_import).process

    expect(TimesheetEntry.where(user: fresh_dup_paul, note: "same work").count).to eq(1)
    expect(fresh_dup_import.reload).to have_attributes(status: "completed", imported_rows: 0, skipped_rows: 2)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:drift_company) { create(:company) }
  let(:drift_actor) { create(:user, current_workspace_id: drift_company.id) }
  let(:drift_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "drift-paul@example.com",
                  current_workspace_id: drift_company.id)
  end
  let(:drift_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: drift_company, name: "Acme LLC"))
  end
  let(:drift_base_url) { "http://timekeeping.test" }
  let(:drift_fake) { TimekeepingContract::FakeTimekeeping.new(token_public_key: timekeeping_key_pair.public_key) }
  let(:drift_import) { create(:data_import, company: drift_company, user: drift_actor) }

  before do
    create(:employment, company: drift_company, user: drift_actor)
    drift_actor.add_role :admin, drift_company
    create(:employment, company: drift_company, user: drift_paul)
    TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).update_columns(owner: "timekeeping", generation: 2)
    drift_fake.generation = 2
    drift_fake.register_company(id: drift_company.id, edit_days: drift_company.timesheet_edit_days)
    drift_fake.register_user(id: drift_actor.id, company_id: drift_company.id, role: "admin")
    drift_fake.register_user(id: drift_paul.id, company_id: drift_company.id, role: "employee")
    drift_fake.register_project(id: drift_project.id, company_id: drift_company.id)
    route_timekeeping_to_fake(drift_fake, base_url: drift_base_url)
    drift_import.file.attach(io: StringIO.new(<<~CSV), filename: "harvest.csv", content_type: "text/csv")
      Date,Client,Project,Hours,First Name,Last Name,Billable?
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes
      2026-01-06,Acme LLC,Website,2,Paul,Connors,Yes
    CSV
  end

  def with_drift_timekeeping(&block)
    with_timekeeping_env(Timekeeping::EntryApiClient::BASE_URL_ENV, drift_base_url) do
      with_timekeeping_env(Timekeeping::UserToken::PRIVATE_KEY_ENV, timekeeping_key_pair.to_pem, &block)
    end
  end

  it "keeps a row's key when the project turns non-billable before a rerun, so Timekeeping refuses it instead of storing it twice" do
    writes = 0
    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_wrap_original do |original, *args, **kwargs|
      writes += 1
      raise Timekeeping::EntryWriteClient::Error, "Timekeeping unavailable" if writes == 2

      original.call(*args, **kwargs)
    end

    with_drift_timekeeping do
      expect { described_class.new(drift_import).process }.to raise_error(Timekeeping::EntryWriteClient::Error)
    end
    first_key = drift_fake.requests.find { |request| request[:method] == "POST" }[:headers]["Idempotency-Key"]

    drift_project.update!(billable: false)
    with_drift_timekeeping do
      expect { described_class.new(drift_import.reload).process }.to raise_error(Timekeeping::EntryWriteClient::Rejected)
    end

    posts = drift_fake.requests.select { |request| request[:method] == "POST" }
    expect(posts.map { |request| request[:headers]["Idempotency-Key"] }).to eq([first_key, first_key])
    expect(drift_fake.outbox.map { |row| row["entry"]["id"] }.uniq.size).to eq(1)
    expect(drift_import.reload).to have_attributes(status: "failed", failed_rows: 0)
  end
end

RSpec.describe Imports::HarvestTimeEntriesImporter do
  let(:rerun_dup_company) { create(:company) }
  let(:rerun_dup_actor) { create(:user, current_workspace_id: rerun_dup_company.id) }
  let(:rerun_dup_paul) do
    create(:user, first_name: "Paul", last_name: "Connors", email: "rerun-dup-paul@example.com",
                  current_workspace_id: rerun_dup_company.id)
  end
  let(:rerun_dup_project) do
    create(:project, name: "Website", billable: true, client: create(:client, company: rerun_dup_company, name: "Acme LLC"))
  end

  before do
    create(:employment, company: rerun_dup_company, user: rerun_dup_actor)
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
    TimesheetEntry.where(user: rerun_dup_paul, note:, source: "import").count
  end

  it "writes a skipped identical row on the third run when the second run failed before writing anything" do
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,same work
    CSV

    rerun_dup_refuse_import_call(2)
    expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    expect(rerun_dup_entries("same work")).to eq(1)

    rerun_dup_refuse_import_call(1)
    expect { described_class.new(import.reload).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    expect(import.reload).to have_attributes(status: "failed", imported_rows: 0)

    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    described_class.new(import.reload).process

    expect(rerun_dup_entries("same work")).to eq(2)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
  end

  it "keeps skipping rows an earlier import already stored when a failed import is rerun" do
    create(:timesheet_entry, project: rerun_dup_project, user: rerun_dup_paul, work_date: Date.new(2026, 1, 5),
                             duration: 60, note: "earlier", bill_status: "unbilled", source: "import")
    import = rerun_dup_import_with(<<~CSV)
      Date,Client,Project,Hours,First Name,Last Name,Billable?,Notes
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,earlier
      2026-01-05,Acme LLC,Website,1,Paul,Connors,Yes,earlier
      2026-01-06,Acme LLC,Website,1,Paul,Connors,Yes,second
      2026-01-07,Acme LLC,Website,1,Paul,Connors,Yes,third
    CSV

    rerun_dup_refuse_import_call(2)
    expect { described_class.new(import).process }.to raise_error(Timekeeping::Gateway::OwnershipMoving)
    expect(rerun_dup_entries("second")).to eq(1)

    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    described_class.new(import.reload).process

    expect(rerun_dup_entries("earlier")).to eq(1)
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

    expect { described_class.new(import).process }.to raise_error(IOError)
    expect(rerun_dup_entries("same work")).to eq(1)

    allow_any_instance_of(Timekeeping::Gateway).to receive(:import).and_call_original
    described_class.new(import.reload).process

    expect(rerun_dup_entries("same work")).to eq(2)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 1)
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

    described_class.new(first_import).process
    described_class.new(second_import).process

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

    described_class.new(import).process

    expect(rerun_dup_entries("before")).to eq(1)
    expect(rerun_dup_entries("after")).to eq(1)
    expect(rerun_dup_entries("rejected")).to eq(0)
    expect(import.reload).to have_attributes(status: "completed", imported_rows: 2, failed_rows: 1)
    expect(import.row_errors.pluck("row")).to eq([3])
  end
end

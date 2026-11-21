# frozen_string_literal: true

require "rails_helper"
require "securerandom"

# The single-writer guard of docs/architecture/timekeeping-soa.md section
# 12.2, run against the live demo runtime
# (spec/support/timekeeping/integrated_runtime.rb) on both seeded companies.
# The runtime hook skips each example unless the live flag it checks is set.
#
# Writes are detected only through the TimekeepingWriterLog trigger
# (spec/support/timekeeping/writer_log.rb), which records the session's
# miru.writer mark for every changed timesheet_entries row, whichever process
# wrote it. Nothing here stubs a writer, the gateway, the projection consumer,
# a relay or the mark: every writer runs through the real code, and the
# projection rows arrive from the runtime's own relay workers.
#
# Each writer case is one measured window: wait until the previous case's
# writes have landed, clear the log, run the case on both companies, wait
# until this case's writes have landed, then read the log. A window closed
# early would let a late write be wiped by the next clear or blamed on the
# wrong case.
RSpec.describe "Timekeeping single-writer guard", type: :request, committed_data: true do
  let(:guard_companies) { [fork_and_leaf, copper_kettle] }

  # The runtime's readiness checks and every in-process Timekeeping call go
  # to 127.0.0.1. An around hook wraps the suite's before hooks, so this is in
  # place before the runtime hook boots the launcher.
  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true)
    example.run
  ensure
    # Back to the suite default (spec/rails_helper.rb), so no later spec may reach localhost.
    WebMock.disable_net_connect!
  end

  describe "section 10.1 writers" do
    it "lets only the projection consumer change entries for every writer while Timekeeping owns the data",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "timekeeping" do
      guard_run_writer_cases(state: "timekeeping")
    end

    it "lets only the projection consumer change entries for every writer after a rollback",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "rollback" do
      guard_run_writer_cases(state: "rollback")
    end
  end

  describe "seed and demo builders" do
    it "refuses all three builders with no logged write while Timekeeping owns the data",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "timekeeping" do
      guard_expect_builders_refused
    end

    it "refuses all three builders with no logged write after a rollback",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "rollback" do
      guard_expect_builders_refused
    end
  end

  describe "negative controls" do
    it "reports unmarked and legacy_gateway writes from another session, and a pooled write after the consumer",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "timekeeping" do
      guard_with_runtime_env do
        TimekeepingWriterLog.guarding(ActiveRecord::Base.connection) do
          installer_pid = guard_backend_pid(ActiveRecord::Base.connection)
          entry_id = guard_seeded_entry(fork_and_leaf).id

          guard_foreign_session_controls(entry_id).each do |label, control|
            TimekeepingWriterLog.clear!
            writer_pid = guard_on_other_session do |connection|
              control.fetch(:write).call(connection)
              guard_backend_pid(connection)
            end

            expect(writer_pid).not_to eq(installer_pid), "#{label}: the control wrote on the installing session"
            rows = TimekeepingWriterLog.rows(include_backend_pid: true)
            expect(rows).to include(a_hash_including(writer: control.fetch(:writer), op: "UPDATE", backend_pid: writer_pid)),
                            "#{label}: the control write was not logged"
            expect(TimekeepingWriterLog.violations(state: "timekeeping", rows:)).not_to be_empty,
                                                                                       "#{label}: the guard reported no violation"
          end

          guard_expect_pooled_write_unmarked(fork_and_leaf)
        end
      end
    end
  end

  describe "legacy owner" do
    it "logs a legacy invoice save as legacy_gateway on both companies",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
      guard_with_runtime_env do
        contexts = guard_companies.map { |company| guard_company_context(company) }
        entries = contexts.to_h do |context|
          session = guard_web_session(context.fetch(:owner))
          [context, guard_web_create(session, context, case_name: "legacy invoice save", note: "Guard legacy invoice")]
        end

        TimekeepingWriterLog.guarding(ActiveRecord::Base.connection) do
          TimekeepingWriterLog.clear!
          entries.each { |context, entry_id| guard_create_draft(context, [entry_id]) }
          TimekeepingGuardDrain.invoice_operations_settled!(case_name: "legacy invoice save")

          rows = TimekeepingWriterLog.rows
          guard_companies.each do |company|
            expect(guard_rows_for(rows, company).pluck(:writer)).to include("legacy_gateway"),
                                                                    "no legacy_gateway row for #{company.name}"
          end
          expect(TimekeepingWriterLog.violations(state: "legacy", rows:)).to be_empty
        end
      end
    end
  end

  # Every section 10.1 writer case, keyed by the case symbols
  # TimekeepingWriterLog::SECTION_10_1_WRITERS maps the doc's paths to. Each
  # runs on one company and answers the projection state each entry it
  # touched must reach before its window closes.
  def guard_writer_cases
    {
      web_mobile_controller: method(:guard_web_case),
      bulk_controller: method(:guard_bulk_case),
      cli_controller: method(:guard_cli_case),
      agent_controller: method(:guard_agent_case),
      harvest_import: method(:guard_harvest_case),
      invoice_reservation: method(:guard_invoice_case),
      agent_destroy: method(:guard_agent_destroy_case)
    }.freeze
  end

  def guard_run_writer_cases(state:)
    guard_with_runtime_env do
      TimekeepingWriterLog.check_section_10_1!(text: Rails.root.join("docs/architecture/timekeeping-soa.md").read)
      cases = guard_writer_cases
      TimekeepingWriterLog.require_cases!(cases.keys)
      guard_advance_entry_ids(state)
      contexts = guard_companies.map { |company| guard_company_context(company) }

      cases.each do |case_name, run_case|
        label = "#{state} #{case_name}"
        guard_drain(state:, case_name: "#{label} (previous case)", expected: {})
        TimekeepingWriterLog.guarding(ActiveRecord::Base.connection) do
          TimekeepingWriterLog.clear!
          expected = contexts.reduce({}) { |all, context| all.merge(run_case.call(context, case_name: label)) }
          guard_drain(state:, case_name: label, expected:)
          guard_expect_only_projection(state:, case_name: label, rows: TimekeepingWriterLog.rows)
        end
      end
    end
  end

  # A window with no projection row for a company fails before violations is
  # read, so a writer that wrote nothing, or a trigger that logged nothing,
  # can never pass on an empty log.
  def guard_expect_only_projection(state:, case_name:, rows:)
    guard_companies.each do |company|
      writers = guard_rows_for(rows, company).pluck(:writer)
      expect(writers).to include("projection"), "#{case_name}: no projection row for #{company.name}"
    end
    expect(TimekeepingWriterLog.violations(state:, rows:)).to eq([]), "#{case_name}: writers other than projection"
  end

  def guard_rows_for(rows, company)
    rows.select { |row| row.fetch(:company_id).to_i == company.id }
  end

  # Moves the owning store's entry id sequence above every seeded id, so an
  # entry a case creates never takes the id of a seeded projection row.
  def guard_advance_entry_ids(state)
    highest = TimesheetEntry.unscoped.maximum(:id)
    next_id = guard_owning_store(state).fetch(:advance).call(highest)
    expect(next_id).to be > highest
  end

  # What each post-handoff state's owning store does for the guard: advance
  # its entry id sequence, and wait until its outbox has been sent.
  def guard_owning_store(state)
    {
      "timekeeping" => {
        advance: ->(above) { guard_timekeeping_store.advance_entry_id_sequence(above:) },
        drain: ->(case_name) { TimekeepingGuardDrain.timekeeping_outbox_drained!(case_name:, store: guard_timekeeping_store) }
      },
      "rollback" => {
        advance: lambda { |above|
          Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection).advance_entry_id_sequence(above:)
        },
        drain: ->(case_name) { TimekeepingGuardDrain.local_outbox_drained!(case_name:) }
      }
    }.fetch(state)
  end

  def guard_timekeeping_store
    Timekeeping::Handoff::TimekeepingStore.new(
      base_url: @integrated_runtime.timekeeping_url, token: @integrated_runtime.credentials.service_token
    )
  end

  # Invoice operations first, because a delivered commit or billing makes
  # entry snapshots of its own; then the entries the case touched; then the
  # owning store's outbox, so no snapshot of this case is still on its way.
  def guard_drain(state:, case_name:, expected:)
    TimekeepingGuardDrain.invoice_operations_settled!(case_name:)
    TimekeepingGuardDrain.entries_settled!(case_name:, expected:) unless expected.empty?
    guard_owning_store(state).fetch(:drain).call(case_name)
  end

  # Points the in-process clients at this example's runtime. They read the
  # URL, the service token and the signing key from ENV on each call, so no
  # initializer is rerun.
  def guard_with_runtime_env(&block)
    credentials = @integrated_runtime.credentials
    env = credentials.to_env.merge(
      Timekeeping::EntryApiClient::BASE_URL_ENV => @integrated_runtime.timekeeping_url,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV => credentials.service_token
    )
    with_timekeeping_env(env, &block)
  end

  # The company's owner, whose current workspace is the company, and two of
  # its billable projects: entries start on the first, and the bulk case
  # moves them to the second.
  def guard_company_context(company)
    owner = User.with_role(:owner, company).find_by!(current_workspace_id: company.id)
    projects = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id)
    project = projects.first!
    { company:, owner:, project:, other_project: projects.where.not(id: project.id).first! }
  end

  def guard_web_session(user)
    ActionDispatch::Integration::Session.new(Rails.application).tap { login_as(user, scope: :user) }
  end

  def guard_request(session, verb, path, case_name:, **options)
    session.public_send(verb, path, as: :json, **options)
    expect(session.response).to have_http_status(:success),
                                "#{case_name}: #{verb.upcase} #{path} answered #{session.response.status}"
    session.response.parsed_body
  end

  def guard_web_create(session, context, case_name:, note:)
    body = guard_request(session, :post, api_v1_timesheet_entry_index_path, case_name:, params: {
      project_id: context.fetch(:project).id, user_id: context.fetch(:owner).id,
      timesheet_entry: { duration: 30, work_date: Date.current.iso8601, note:, bill_status: "unbilled" }
    })
    body.fetch("entry").fetch("id")
  end

  def guard_entries_projected(case_name, expected)
    TimekeepingGuardDrain.entries_settled!(case_name:, expected:)
  end

  def guard_web_case(context, case_name:)
    session = guard_web_session(context.fetch(:owner))
    edited = guard_web_create(session, context, case_name:, note: "Guard web create")
    deleted = guard_web_create(session, context, case_name:, note: "Guard web delete")
    guard_entries_projected(case_name, edited => {}, deleted => {})

    guard_request(session, :patch, api_v1_timesheet_entry_path(edited), case_name:, params: {
      project_id: context.fetch(:project).id,
      timesheet_entry: { duration: 45, work_date: Date.current.iso8601, note: "Guard web edit", bill_status: "unbilled" }
    })
    guard_request(session, :delete, api_v1_timesheet_entry_path(deleted), case_name:)

    { edited => { "note" => "Guard web edit" }, deleted => { "discarded?" => true } }
  end

  def guard_bulk_case(context, case_name:)
    session = guard_web_session(context.fetch(:owner))
    moved = guard_web_create(session, context, case_name:, note: "Guard bulk move")
    deleted = guard_web_create(session, context, case_name:, note: "Guard bulk delete")
    guard_entries_projected(case_name, moved => {}, deleted => {})

    other_project = context.fetch(:other_project)
    move_params = { ids: [moved, deleted], project_id: other_project.id }
    guard_request(session, :patch, api_v1_bulk_action_path, case_name:, params: move_params)
    guard_request(session, :delete, api_v1_bulk_action_path, case_name:, params: { source: { ids: [deleted] } })

    { moved => { "project_id" => other_project.id }, deleted => { "discarded?" => true } }
  end

  def guard_cli_case(context, case_name:)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    headers = cli_auth_headers(CliSession.issue_for(user: context.fetch(:owner), company: context.fetch(:company)).last)
    project_id = context.fetch(:project).id
    created = %w[edit delete].map do |purpose|
      guard_request(session, :post, api_v1_cli_timesheet_entries_path, case_name:, headers:, params: {
        timesheet_entry: { project_id:, duration_minutes: 30, work_date: Date.current.iso8601,
                           note: "Guard cli #{purpose}", bill_status: "unbilled" }
      }).fetch("entry").fetch("id")
    end
    edited, deleted = created
    guard_entries_projected(case_name, edited => {}, deleted => {})

    guard_request(session, :patch, api_v1_cli_timesheet_entry_path(edited), case_name:, headers:, params: {
      timesheet_entry: { project_id:, duration_minutes: 50, work_date: Date.current.iso8601, note: "Guard cli edited" }
    })
    guard_request(session, :delete, api_v1_cli_timesheet_entry_path(deleted), case_name:, headers:)

    # The created note is "Guard cli edit", so only a written update reaches this one.
    { edited => { "note" => "Guard cli edited" }, deleted => { "discarded?" => true } }
  end

  def guard_agent_case(context, case_name:)
    agent = guard_agent(context)
    entry_id = guard_agent_create(agent, context, case_name:)

    { entry_id => { "agent_id" => agent.id } }
  end

  # An agent whose user is an employee and member of the context's project,
  # so the agent API may log time on it.
  def guard_agent(context)
    company = context.fetch(:company)
    project = context.fetch(:project)
    agent = create(:agent, company:, default_project: project)
    agent.user.add_role :employee, company
    create(:project_member, user: agent.user, project:)
    agent
  end

  def guard_agent_create(agent, context, case_name:)
    token = AgentKey.issue_for(agent:, name: "Guard key", created_by: context.fetch(:owner)).last
    session = ActionDispatch::Integration::Session.new(Rails.application)
    params = {
      timesheet_entry: {
        project_id: context.fetch(:project).id, duration_minutes: 30, work_date: Date.current.iso8601,
        note: "Guard agent entry"
      }
    }
    body = guard_request(session, :post, api_v1_agent_timesheet_entries_path, case_name:,
                         headers: { "Authorization" => "Bearer #{token}" }, params:)
    body.fetch("entry").fetch("id")
  end

  # The fixture file, the project its rows name, and how many rows it holds.
  def guard_harvest_fixture
    { file: "single_writer_guard_harvest.csv", project: "Writer Guard Project", rows: 2 }.freeze
  end

  # The fixture's person matches no one, so each company's import assigns its
  # rows to that company's owner.
  def guard_harvest_case(context, case_name:)
    company = context.fetch(:company)
    owner = context.fetch(:owner)
    fixture = guard_harvest_fixture
    data_import = create(:data_import, company:, user: owner, options: { "assign_unmatched_to" => owner.email })
    file_fixture(fixture.fetch(:file)).open do |io|
      data_import.file.attach(io:, filename: fixture.fetch(:file), content_type: "text/csv")
    end
    Imports::HarvestTimeEntriesImporter.new(data_import).process
    expect(data_import.reload.imported_rows).to eq(fixture.fetch(:rows)), "#{case_name}: #{company.name} import"

    entry_ids = TimekeepingGuardDrain.poll_until(case_name:, awaiting: "#{company.name} imported entries projected") do
      ids = TimesheetEntry.uncached do
        TimesheetEntry.unscoped.joins(project: :client)
          .where(projects: { name: fixture.fetch(:project) }, clients: { company_id: company.id }).pluck(:id)
      end
      ids if ids.size == fixture.fetch(:rows)
    end
    entry_ids.index_with { {} }
  ensure
    data_import&.file&.purge
  end

  # Adds two fresh entries to a draft once both are projected, removes one
  # line, then bills the invoice the way InvoiceMailer#update_status does: a
  # non-draft save sends no reservation, so billing is its own call.
  def guard_invoice_case(context, case_name:)
    session = guard_web_session(context.fetch(:owner))
    billed = guard_web_create(session, context, case_name:, note: "Guard invoice billed")
    released = guard_web_create(session, context, case_name:, note: "Guard invoice released")
    guard_entries_projected(case_name, billed => {}, released => {})

    invoice = guard_create_draft(context, [billed, released])
    TimekeepingGuardDrain.invoice_operations_settled!(case_name:)
    released_line = invoice.invoice_line_items.find_by!(timesheet_entry_id: released)
    invoice.update!(invoice_line_items_attributes: [{ id: released_line.id, _destroy: true }])
    TimekeepingGuardDrain.invoice_operations_settled!(case_name:)

    invoice.reload
    Timekeeping::BillingFence.transaction do
      invoice.sent!
      Invoices::ReservationBoundary.mark_billed(invoice)
    end

    { billed => { "bill_status" => "billed" }, released => { "bill_status" => "unbilled", "locked" => false } }
  end

  def guard_create_draft(context, entry_ids)
    company = context.fetch(:company)
    lines = TimesheetEntry.unscoped.where(id: entry_ids).order(:id).map do |entry|
      { name: "Guard #{entry.id}", description: "guard", date: entry.work_date, rate: 100,
        quantity: entry.duration, timesheet_entry_id: entry.id }
    end
    Invoice.create!(
      company:, client: context.fetch(:project).client, invoice_number: "GUARD-#{SecureRandom.hex(4)}",
      issue_date: Date.current, due_date: Date.current + 30, status: :draft, currency: company.base_currency,
      invoice_line_items_attributes: lines
    )
  end

  def guard_agent_destroy_case(context, case_name:)
    agent = guard_agent(context)
    entry_id = guard_agent_create(agent, context, case_name:)
    guard_entries_projected(case_name, entry_id => { "agent_id" => agent.id })

    agent.destroy!
    expect(Agent.exists?(agent.id)).to be(false), "#{case_name}: the agent was not destroyed"

    { entry_id => { "agent_id" => nil } }
  end

  # Each builder runs after a marked control write that the log is seen to
  # record and is then cleared, so its empty log after the refusal shows the
  # trigger was live, not missing.
  def guard_expect_builders_refused
    builders = {
      "db/seeds.rb" => -> { load Rails.root.join("db/seeds.rb") },
      "db/seeds/timesheet_data.rb" => -> { load Rails.root.join("db/seeds/timesheet_data.rb") },
      "Analytics::DemoSeeder" => -> { Analytics::DemoSeeder.new(company: fork_and_leaf).process }
    }
    entry_id = guard_seeded_entry(fork_and_leaf).id

    guard_with_runtime_env do
      TimekeepingWriterLog.guarding(ActiveRecord::Base.connection) do
        builders.each do |name, build|
          guard_marked_write(ActiveRecord::Base.connection, entry_id)
          expect(TimekeepingWriterLog.rows).to include(a_hash_including(writer: "legacy_gateway", op: "UPDATE")),
                                               "#{name}: the control write was not logged"
          TimekeepingWriterLog.clear!

          expect { build.call }.to raise_error(TimekeepingOwnership::HandoffBegun), name
          expect(TimekeepingWriterLog.rows).to eq([]), "#{name}: wrote timesheet_entries before refusing"
        end
      end
    end
  end

  def guard_foreign_session_controls(entry_id)
    {
      "unmarked write" => { writer: nil, write: ->(connection) { guard_touch(connection, entry_id) } },
      "legacy_gateway write" => { writer: "legacy_gateway", write: ->(connection) { guard_marked_write(connection, entry_id) } }
    }
  end

  # The mark is SET LOCAL and opens no transaction of its own, so the
  # transaction here is what keeps it on for the write.
  def guard_marked_write(connection, entry_id)
    connection.transaction do
      Timekeeping::LegacyWriterMark.call(connection) { guard_touch(connection, entry_id) }
    end
  end

  def guard_touch(connection, entry_id)
    updated = connection.update("UPDATE timesheet_entries SET note = note WHERE id = #{Integer(entry_id)}")
    expect(updated).to eq(1), "entry #{entry_id} was not updated"
  end

  def guard_seeded_entry(company)
    TimesheetEntry.unscoped.joins(project: :client).where(clients: { company_id: company.id }).order(:id).first!
  end

  def guard_backend_pid(connection)
    connection.select_value("SELECT pg_backend_pid()")
  end

  # Runs the block on a connection leased on another thread and answers its
  # value.
  def guard_on_other_session(&block)
    thread = committed_data_thread { block.call(ActiveRecord::Base.connection) }
    thread.value
  ensure
    stop_committed_data_threads(thread)
  end

  # The consumer marks its own transaction with SET LOCAL. Run with no
  # transaction open around it, that mark ends when the consumer commits, so
  # the next write on the same pooled connection carries no mark.
  def guard_expect_pooled_write_unmarked(company)
    seeded = guard_seeded_entry(company)
    entry_id = TimesheetEntry.unscoped.maximum(:id) + 1_000
    snapshot = TimekeepingSnapshots.entry(id: entry_id, company_id: company.id, version: 1,
                                          project_id: seeded.project_id, user_id: seeded.user_id)
    batch = TimekeepingSnapshots.batch(
      TimekeepingSnapshots.item(snapshot, generation: TimekeepingOwnership.current.generation)
    )
    TimekeepingWriterLog.clear!

    ActiveRecord::Base.connection_pool.with_connection do |connection|
      expect(connection.open_transactions).to eq(0)
      result = Timekeeping::ProjectionConsumer.call(batch:, idempotency_key: "single-writer-guard-#{entry_id}")
      expect(result.status).to eq(200)
      guard_touch(connection, entry_id)
    end

    rows = TimekeepingWriterLog.rows(include_backend_pid: true)
    consumer_row = rows.find { |row| row.fetch(:op) == "INSERT" }
    update_row = rows.find { |row| row.fetch(:op) == "UPDATE" }
    expect(consumer_row).to include(writer: "projection")
    expect(update_row.fetch(:writer)).not_to eq("projection")
    expect(update_row.fetch(:backend_pid)).to eq(consumer_row.fetch(:backend_pid))
  end
end

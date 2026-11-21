# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "net/http"
require "securerandom"
require "tmpdir"

# Section 12.4 scenarios of docs/architecture/timekeeping-soa.md, run against
# the live demo runtime (spec/support/timekeeping/integrated_runtime.rb) with
# real handoffs through Timekeeping::Handoff::Runner.configured_owners. Each
# example needs TIMEKEEPING_LIVE=1 and TIMEKEEPING_DATABASE_URL; the runtime
# hook skips it otherwise.
#
# Ownership is one global row, so every example arranges both seeded
# companies first, makes each handoff, fence or abort once, and only then
# acts on and asserts each company. A transition inside a per-company loop
# would measure the second company in a state the first one already changed.
RSpec.describe "Timekeeping extraction scenarios", type: :request do
  let(:extraction_companies) { [fork_and_leaf, copper_kettle] }
  let(:extraction_audits) { Audited::Audit.where(action: "super_admin_delete") }

  # db/seeds.rb has no super admin. SuperAdmin#super_admin? needs a confirmed
  # hello@saeloun.com, and the controller authorizes before the handoff
  # check, so the actor is created with an admin role in each company.
  let(:extraction_super_admin) do
    create(:user, email: "hello@saeloun.com", current_workspace_id: fork_and_leaf.id).tap do |admin|
      extraction_companies.each do |company|
        create(:employment, company:, user: admin)
        admin.add_role :admin, company
      end
    end
  end

  describe "user hard delete refused once extraction has begun" do
    it "refuses while only the monolith admission fence is set, for users with agents, and deletes again after an abort admits",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
      extraction_with_runtime do
        targets = extraction_companies.index_with { |company| extraction_agent_target(company) }
        sign_in extraction_super_admin
        audit_baseline = extraction_audits.count

        Timekeeping::Handoff::Runner.configured_owners["monolith"].admission.fence_admission
        expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil

        targets.each_value do |target|
          extraction_delete(target[:user])

          # 422, not the 503 the agent detach would answer if the delete got that far.
          extraction_expect_handoff_refusal
          expect(User.exists?(target[:user].id)).to be(true)
          expect(Agent.exists?(target[:agent].id)).to be(true)
          expect(TimesheetEntry.unscoped.find(target[:entry_id]).agent_id).to eq(target[:agent].id)
        end
        expect(extraction_audits.count).to eq(audit_baseline)

        # With no step recorded, an abort runs only the monolith admission's admit.
        extraction_run_handoff(direction: :cutover, abort: true)
        expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil

        targets.each_value.with_index(1) do |target, deleted|
          extraction_delete(target[:user])

          expect(response).to have_http_status(:ok)
          expect(User.exists?(target[:user].id)).to be(false)
          expect(extraction_audits.count).to eq(audit_baseline + deleted)
        end
      end
    end

    it "refuses a first entry's user with the relay paused after cutover, and again after the rollback projected the entry",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
      extraction_with_runtime do
        targets = extraction_companies.index_with { |company| extraction_employee(company) }
        sign_in extraction_super_admin
        audit_baseline = extraction_audits.count

        extraction_run_handoff(direction: :cutover)
        expect(TimekeepingOwnership.current.owner).to eq("timekeeping")

        extraction_pause_relay!
        entry_ids = targets.to_h { |company, target| [company, extraction_create_entry(company, target)] }

        targets.each do |company, target|
          extraction_delete(target[:user])

          extraction_expect_handoff_refusal
          expect(User.exists?(target[:user].id)).to be(true)
          expect(extraction_timekeeping_entry(company, entry_ids.fetch(company)).fetch("id")).to eq(entry_ids.fetch(company))
          # The relay is paused, so the projection has not received the entry yet.
          expect(TimesheetEntry.unscoped.exists?(entry_ids.fetch(company))).to be(false)
        end
        expect(extraction_audits.count).to eq(audit_baseline)

        extraction_resume_relay!
        # The rollback's freeze step drains Timekeeping's outbox through the
        # relay, so the entries are projected once it returns.
        extraction_run_handoff(direction: :rollback)
        expect(TimekeepingOwnership.current.monolith_store).to eq("prepared")

        targets.each do |company, target|
          expect(TimesheetEntry.unscoped.exists?(entry_ids.fetch(company))).to be(true)

          extraction_delete(target[:user])

          extraction_expect_handoff_refusal
          expect(User.exists?(target[:user].id)).to be(true)
          expect(TimesheetEntry.unscoped.exists?(entry_ids.fetch(company))).to be(true)
        end
        expect(extraction_audits.count).to eq(audit_baseline)
      end
    end

    it "refuses a seeded user's hard delete in the rollback owner state and keeps the user and the entry",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "rollback" do
      extraction_with_runtime do
        seeded_entries = extraction_companies.map { |company| extraction_seeded_non_owner_entry(company) }
        sign_in extraction_super_admin
        audit_baseline = extraction_audits.count

        seeded_entries.each do |entry|
          extraction_delete(entry.user)

          extraction_expect_handoff_refusal
          expect(User.exists?(entry.user_id)).to be(true)
          expect(TimesheetEntry.unscoped.exists?(entry.id)).to be(true)
        end
        expect(extraction_audits.count).to eq(audit_baseline)
      end
    end
  end

  describe "aggregate line removed from a draft" do
    it "releases only the entries no remaining line references, and keeps every reservation when a save or destroy fails",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
      extraction_with_runtime do
        entries = extraction_companies.index_with { |company| extraction_open_entries(company, count: 3) }
        sign_in extraction_super_admin

        extraction_run_handoff(direction: :cutover)
        expect(TimekeepingOwnership.current.owner).to eq("timekeeping")

        drafts = entries.to_h do |company, (x, y, z)|
          holder = extraction_create_draft(company, x.project.client, [extraction_direct_line(z)])
          draft = extraction_create_draft(company, x.project.client,
                                          [extraction_direct_line(x), extraction_grouped_line([x, y])])
          [company, { draft:, holder: }]
        end

        entries.each do |company, (x, y, z)|
          draft = drafts.dig(company, :draft)
          expect(extraction_reserved_ids(company, [x, y, z])).to eq([x.id, y.id, z.id])

          grouped_line = draft.invoice_line_items.find_by!(timesheet_entry_id: nil)
          extraction_save_draft(company, draft, [extraction_removed_line(grouped_line)])

          expect(response).to have_http_status(:ok)
          # The direct line still references X, so only Y is released.
          expect(extraction_reserved_ids(company, [x, y, z])).to eq([x.id, z.id])

          # Removing the direct line alone would release X; adding Z, which the
          # holder draft keeps, makes Timekeeping refuse the whole save, so X
          # must stay reserved and the direct line must stay on the draft.
          direct_line = draft.invoice_line_items.find_by!(timesheet_entry_id: x.id)
          extraction_save_draft(company, draft, [extraction_removed_line(direct_line), extraction_direct_line(z)])

          expect(response).to have_http_status(:unprocessable_content)
          expect(json_response["errors"]).to eq("entry is on another invoice")
          expect(InvoiceLineItem.exists?(direct_line.id)).to be(true)
          expect(extraction_reserved_ids(company, [x, y, z])).to eq([x.id, z.id])

          extraction_save_draft(company, draft, [extraction_removed_line(direct_line)])

          expect(response).to have_http_status(:ok)
          expect(extraction_reserved_ids(company, [x, y])).to eq([])

          extraction_save_draft(company, draft, [extraction_direct_line(x), extraction_grouped_line([x, y])])

          expect(response).to have_http_status(:ok)
          expect(extraction_reserved_ids(company, [x, y])).to eq([x.id, y.id])
        end

        timekeeping_admission = Timekeeping::Handoff::Runner.configured_owners["timekeeping"].admission
        timekeeping_admission.fence_admission
        begin
          entries.each do |company, (x, y, z)|
            draft = drafts.dig(company, :draft)
            extraction_act_in(company)

            # Timekeeping refuses every reservation write while it admits no
            # generation, so the release the destroy needs is refused.
            expect { send_request :delete, api_v1_invoice_path(draft), headers: auth_headers(extraction_super_admin) }
              .to raise_error(Invoices::OperationErrors::PrepareRetryable, "stale_generation")
            expect(draft.reload.discarded_at).to be_nil
            expect(extraction_reserved_ids(company, [x, y, z])).to eq([x.id, y.id, z.id])
          end
        ensure
          timekeeping_admission.admit(generation: TimekeepingOwnership.current.generation)
        end

        entries.each do |company, (x, y, z)|
          draft = drafts.dig(company, :draft)
          extraction_act_in(company)
          send_request :delete, api_v1_invoice_path(draft), headers: auth_headers(extraction_super_admin)

          expect(response).to have_http_status(:success)
          expect(draft.reload.discarded_at).not_to be_nil
          # The whole set is released; Z belongs to the other draft and stays.
          expect(extraction_reserved_ids(company, [x, y, z])).to eq([z.id])
        end
      end
    end
  end

  describe "checkpoint load re-run" do
    it "loads the held cutover's checkpoint twice with equal row counts and checksums, then resumes to the flip",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
      extraction_with_runtime do
        generation_before = TimekeepingOwnership.current.generation

        extraction_with_report_root do |report_root|
          expect do
            Timekeeping::Handoff::Runner.run(direction: :cutover, report_root:,
                                             observer: TimekeepingHandoffHooks::Interrupt.new(at: :after_checkpoint))
          end.to raise_error(TimekeepingHandoffHooks::Interrupted)
          expect(TimekeepingOwnership.current).to have_attributes(owner: "monolith", handoff_step: "checkpoint")
          # Timekeeping stays fenced until the flip admits it.
          expect(extraction_timekeeping_admitted_generation).to be_nil

          store = Timekeeping::Handoff::TimekeepingStore.new
          exported = store.export_checkpoint
          first_load = store.load_checkpoint(exported)
          second_load = store.load_checkpoint(exported)

          expect(extraction_row_counts(second_load)).to eq(extraction_row_counts(first_load))
          expect(extraction_row_counts(first_load)).to eq(extraction_row_counts(exported))
          expect(second_load.digest).to eq(first_load.digest)
          expect(first_load.digest).to eq(exported.digest)
          extraction_companies.each do |company|
            expect(exported.digest.fetch("entries").fetch(company.id).fetch(:count)).to be_positive
          end

          Timekeeping::Handoff::Runner.run(direction: :cutover, report_root:)
        end

        ownership = TimekeepingOwnership.current
        expect(ownership).to have_attributes(owner: "timekeeping", handoff_step: nil)
        expect(ownership.generation).to be > generation_before
      end
    end
  end

  describe "report parity" do
    # Each reader that section 1.7 of docs/architecture/timekeeping-soa.md
    # lists, with what it returns for one company and a probe that must be
    # positive before cutover. Several readers return fixed keys or zeros even
    # when no entry matches, so the probe proves each one read seeded entries
    # and the comparison cannot pass on empty output.
    extraction_report_readers = [
      {
        name: "Reports::TimeEntries::ReportService",
        read: lambda do |context|
          # The reader orders entries by client and work_date only and returns
          # pages of 50, so entries that share a date come back in whatever
          # order Postgres reads the rows, and a page boundary can fall among
          # them. The projection rewrites those rows at cutover, which changes
          # that order. The last day alone fits in one page, and the
          # normalizer below puts its ties in id order.
          day = context[:to].iso8601
          params = ActionController::Parameters.new(group_by: "client", date_range: "custom", from: day, to: day)
          travel_to(context[:day]) { Reports::TimeEntries::ReportService.new(params, context[:company]).process }
        end,
        normalize: lambda do |output|
          output.merge("reports" => output.fetch("reports").map do |group|
            group.merge("entries" => group.fetch("entries").sort_by { |entry| entry.fetch("id") })
          end)
        end,
        probe: ->(output, _context) { output.dig("group_by_total_duration", "grouped_durations").values.sum }
      },
      {
        name: "Analytics::TeamProductivityAnalytics",
        read: lambda do |context|
          Analytics::TeamProductivityAnalytics.new(company: context[:company], from: context[:from], to: context[:to]).process
        end,
        probe: ->(output, _context) { output.dig("summary", "total_hours") }
      },
      {
        name: "Metrics::DataBuilder hours_logged",
        read: lambda do |context|
          Metrics::DataBuilder.build(Metric.new(trackable: context[:company], metric_type: "hours_logged", period: "all_time"))
        end,
        probe: ->(output, _context) { output.fetch("entry_count") }
      },
      {
        name: "Reports::ClientRevenues hours_logged_by_client",
        read: lambda do |context|
          Reports::ClientRevenues::ReportDecorator.new(
            ActiveSupport::HashWithIndifferentAccess.new(from: context[:from].iso8601, to: context[:to].iso8601), context[:company]
          ).process
        end,
        probe: ->(output, _context) { output.dig("summary", "total_hours") }
      },
      {
        name: "Api::V1::ProjectsController#index total durations",
        read: lambda do |context|
          extraction_act_in(context[:company])
          send_request :get, api_v1_projects_path, headers: auth_headers(extraction_super_admin)
          expect(response).to have_http_status(:ok)
          json_response
        end,
        probe: ->(output, _context) { output.fetch("projects").sum { |project| project.fetch("totalHours") } }
      },
      {
        name: "Client and Project totals",
        read: lambda do |context|
          travel_to(context[:day]) do
            clients = context[:company].clients.kept.order(:id)
            {
              clients: clients.map { |client| [client.id, client.total_hours_logged("month")] },
              projects: Project.where(client: clients).order(:id).map do |project|
                [project.id, project.total_logged_duration("month"), project.minutes_spent]
              end
            }
          end
        end,
        probe: ->(output, _context) { output.fetch("clients").sum(&:last) }
      },
      {
        name: "Clients::IndexService",
        read: lambda do |context|
          travel_to(context[:day]) do
            Clients::IndexService.new(context[:company], extraction_super_admin, nil, "month").process
          end
        end,
        probe: ->(output, _context) { output.fetch("total_minutes") }
      },
      {
        name: "Team::IndexDecorator",
        read: lambda do |context|
          travel_to(context[:day]) do
            Team::IndexDecorator.new(current_company: context[:company], current_user: extraction_super_admin).process
          end
        end,
        probe: ->(output, _context) { output.fetch("combined_data").sum { |member| member["hours_logged"].to_f } }
      },
      {
        name: "Team::RemovalImpactService",
        read: lambda do |context|
          Team::RemovalImpactService.new(current_company: context[:company], member: context[:member]).process
        end,
        # The reader lists project names in no defined order.
        normalize: ->(output) { output.merge("project_names" => output.fetch("project_names").sort) },
        probe: ->(output, _context) { output.fetch("unbilled_entries_count") + output.fetch("invoiced_entries_count") }
      },
      {
        name: "WeeklyReminderForMissedEntriesService",
        read: ->(context) { extraction_weekly_reminders(context) },
        # This reader answers only whether each member is reminded, so the
        # probe checks that the week it reads holds the members' entries.
        probe: lambda do |output, context|
          TimesheetEntry.kept.in_workspace(context[:company])
            .where(user_id: output.map(&:first), work_date: context[:day].to_date.all_week).count
        end
      },
      {
        name: "Analytics::GrowthMetricsService",
        read: ->(_context) { Analytics::GrowthMetricsService.process },
        probe: lambda do |output, context|
          output.fetch("top_workspaces").find { |workspace| workspace["id"] == context[:company].id }.fetch("activity_score")
        end
      },
      {
        name: "TimeTrackingIndexService",
        read: lambda do |context|
          TimeTrackingIndexService.new(current_user: extraction_super_admin, user: context[:member], company: context[:company],
                                       from: context[:from], to: context[:to], year: context[:to].year).process
        end,
        # Neither the legacy query nor Timekeeping's list orders the entries
        # of one day, so each day's list is put in id order.
        normalize: lambda do |output|
          output.merge("entries" => output.fetch("entries").transform_values do |day|
            day.sort_by { |entry| [entry["type"].to_s, entry.fetch("id")] }
          end)
        end,
        probe: ->(output, _context) { output.fetch("entries").values.sum(&:size) }
      },
      {
        # Only project_stats runs the bill_status: :billable filters section
        # 1.7 names, and it calls Project#invoices, which Project does not
        # define. The project is given an empty invoices relation, so the
        # real method runs every entry query; invoices do not move at cutover.
        name: "Metrics::DataBuilder project_stats",
        read: lambda do |context|
          project = Project.find(extraction_busiest_project_id(context[:company]))
          project.define_singleton_method(:invoices) { Invoice.none }
          Metrics::DataBuilder.build(Metric.new(trackable: project, metric_type: "project_stats", period: "all_time"))
        end,
        probe: ->(output, _context) { output.fetch("total_entries") }
      },
      {
        # Its only caller, user_activity_summary, fails on every request
        # because User has no ahoy_events association, so the relation is read
        # from the controller directly, as the company's owner sees it.
        name: "AnalyticsController#analytics_timesheet_entries",
        read: lambda do |context|
          owner = User.with_role(:owner, context[:company]).order(:id).first!
          controller = AnalyticsController.new
          controller.define_singleton_method(:current_user) { owner }
          entries = controller.send(:analytics_timesheet_entries)
          travel_to(context[:day]) do
            {
              hours_logged_today: entries.where(work_date: Date.current).sum(:duration) / 60.0,
              entries: entries.order(:id).pluck(:id, :duration, :work_date)
            }
          end
        end,
        probe: ->(output, _context) { output.fetch("entries").size }
      }
    ].map(&:freeze).freeze

    it "returns the same output from every section 1.7 reader after cutover as from timesheet_entries before it",
       :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
      extraction_with_runtime do
        contexts = extraction_companies.map { |company| extraction_report_context(company) }
        sign_in extraction_super_admin

        read_all = lambda do
          contexts.to_h do |context|
            outputs = extraction_report_readers.to_h do |reader|
              output = JSON.parse(instance_exec(context, &reader[:read]).to_json)
              [reader[:name], reader.fetch(:normalize, :itself.to_proc).call(output)]
            end
            [context[:company].name, outputs]
          end
        end

        before_cutover = read_all.call
        contexts.each do |context|
          extraction_report_readers.each do |reader|
            probe = reader[:probe].call(before_cutover.dig(context[:company].name, reader[:name]), context)
            expect(probe).to be_positive, "#{reader[:name]} read no entries for #{context[:company].name}"
          end
        end

        extraction_run_handoff(direction: :cutover)
        expect(TimekeepingOwnership.current.owner).to eq("timekeeping")
        after_cutover = read_all.call

        aggregate_failures do
          contexts.each do |context|
            extraction_report_readers.each do |reader|
              expect(after_cutover.dig(context[:company].name, reader[:name]))
                .to eq(before_cutover.dig(context[:company].name, reader[:name])),
                    "#{reader[:name]} changed across cutover for #{context[:company].name}"
            end
          end
        end
      end
    end
  end

  # Points the in-process app at this example's runtime, rebuilds the handoff
  # integrations from that environment, and undoes both afterwards. The
  # signing key travels with the URL and service token: forwarded entry
  # writes mint user tokens with it, and the runtime's Timekeeping trusts only
  # the key pair generated for this run.
  def extraction_with_runtime(&block)
    WebMock.disable_net_connect!(allow_localhost: true)
    with_timekeeping_env(extraction_runtime_env) do
      extraction_rebuild_integrations
      block.call
    ensure
      # A relay left paused would hold back every snapshot of the next example.
      extraction_resume_relay! if @extraction_relay_paused
    end
  ensure
    # ENV is restored by now, so the integrations go back to the suite's own.
    extraction_rebuild_integrations
  end

  def extraction_runtime_env
    credentials = @integrated_runtime.credentials
    credentials.to_env.merge(
      Timekeeping::EntryApiClient::BASE_URL_ENV => @integrated_runtime.timekeeping_url,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV => credentials.service_token
    )
  end

  # Reruns only the handoff initializer, as handoff_live_spec.rb does:
  # rerunning every to_prepare hook reloads FactoryBot, which fails on the
  # seed's top-level helper methods.
  def extraction_rebuild_integrations
    allow(Rails.application.config).to receive(:to_prepare).and_yield
    load Rails.root.join("config/initializers/timekeeping_handoff.rb").to_s
  end

  # Each run writes its money snapshot and checkpoint files into its own
  # directory, so no run resumes from another run's files.
  def extraction_run_handoff(**options)
    extraction_with_report_root { |report_root| Timekeeping::Handoff::Runner.run(**options, report_root:) }
  end

  # A resumed run must read the files the interrupted run wrote, so both share
  # the directory this yields.
  def extraction_with_report_root
    report_root = Pathname(Dir.mktmpdir("timekeeping-extraction"))
    yield report_root
  ensure
    FileUtils.rm_rf(report_root) if report_root
  end

  # The flag is set first: a pause the server applied but whose answer was
  # lost must still be resumed by teardown. Resuming an unpaused relay only
  # removes a file that is not there.
  def extraction_pause_relay!
    @extraction_relay_paused = true
    extraction_relay_hook("pause")
  end

  def extraction_resume_relay!
    extraction_relay_hook("resume")
    @extraction_relay_paused = false
  end

  def extraction_relay_hook(action)
    uri = URI.join(@integrated_runtime.timekeeping_url, "/internal/v1/test-hooks/relay/#{action}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@integrated_runtime.credentials.service_token}"
    answer = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
    raise "relay #{action} answered #{answer.code}" unless answer.is_a?(Net::HTTPSuccess)
  end

  def extraction_delete(user)
    send_request :delete, api_v1_user_path(user), headers: auth_headers(extraction_super_admin)
  end

  def extraction_expect_handoff_refusal
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["errors"]).to eq(I18n.t("user.super_admin_delete.handoff_begun"))
  end

  def extraction_billable_project(company)
    Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
  end

  # A new employee who is a member of one of the company's billable projects,
  # with no entries yet.
  def extraction_employee(company)
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    user.add_role :employee, company
    project = extraction_billable_project(company)
    create(:project_member, user:, project:)
    { user:, project: }
  end

  # A user who has an agent and an entry the agent logged. The entry is moved
  # to another employee, so a successful delete of the agent's user only
  # detaches it, as spec/requests/api/v1/users/destroy_spec.rb arranges it.
  def extraction_agent_target(company)
    agent = create(:agent, company:)
    agent.user.add_role :employee, company
    entry = create(:timesheet_entry, project: extraction_billable_project(company), user: agent.user, agent:)
    TimesheetEntry.unscoped.where(id: entry.id).update_all(user_id: extraction_employee(company)[:user].id)
    { user: agent.user, agent:, entry_id: entry.id }
  end

  # Creates the target's first entry through the web API, which forwards it to
  # Timekeeping while Timekeeping owns the entries, and answers its id.
  def extraction_create_entry(company, target)
    extraction_act_in(company)
    send_request :post, api_v1_timesheet_entry_index_path, params: {
      project_id: target[:project].id, user_id: target[:user].id,
      timesheet_entry: { duration: 30, work_date: Date.current.iso8601, note: "First entry", bill_status: "unbilled" }
    }, headers: auth_headers(extraction_super_admin)
    expect(response).to have_http_status(:ok)
    json_response.fetch("entry").fetch("id")
  end

  # Reads the entry from Timekeeping itself, not from the projection.
  def extraction_timekeeping_entry(company, entry_id)
    Timekeeping::EntryApiClient.new.show_entry(
      company_id: company.id, entry_id:, acting_user_id: extraction_super_admin.id, request_id: SecureRandom.uuid
    )
  end

  # The super admin is admin in both companies; requests act in its current
  # workspace. update_columns leaves updated_at alone, so readers that return
  # the user record read the same row before and after cutover.
  def extraction_act_in(company)
    extraction_super_admin.update_columns(current_workspace_id: company.id)
  end

  # Unbilled, unlocked entries of a new employee on a billable project. They
  # are written before cutover, so the checkpoint carries them to Timekeeping.
  def extraction_open_entries(company, count:)
    employee = extraction_employee(company)
    create_list(:timesheet_entry, count, user: employee[:user], project: employee[:project], bill_status: :unbilled,
                                         locked: false, duration: 60)
  end

  def extraction_direct_line(entry)
    { name: "Direct #{entry.id}", description: "direct", date: entry.work_date.iso8601, rate: 100,
      quantity: entry.duration, timesheet_entry_id: entry.id }
  end

  def extraction_grouped_line(entries)
    { name: "Grouped", description: "grouped", date: entries.first.work_date.iso8601, rate: 100,
      quantity: entries.sum(&:duration), linked_timesheet_entry_ids: entries.map(&:id) }
  end

  def extraction_removed_line(line)
    { id: line.id, name: line.name, date: line.date.iso8601, rate: line.rate, quantity: line.quantity, _destroy: true }
  end

  def extraction_invoice_fields(company, client)
    { client_id: client.id, issue_date: Date.current.iso8601, due_date: 30.days.from_now.to_date.iso8601,
      status: "draft", currency: company.base_currency }
  end

  def extraction_create_draft(company, client, lines)
    extraction_act_in(company)
    send_request :post, api_v1_invoices_path, params: {
      invoice: extraction_invoice_fields(company, client).merge(
        invoice_number: "EXT-#{SecureRandom.hex(4)}", invoice_line_items_attributes: lines
      )
    }, headers: auth_headers(extraction_super_admin)
    expect(response).to have_http_status(:ok)
    Invoice.find(json_response.fetch("id"))
  end

  def extraction_save_draft(company, draft, lines)
    extraction_act_in(company)
    send_request :patch, api_v1_invoice_path(draft), params: {
      invoice: extraction_invoice_fields(company, draft.client).merge(
        invoice_number: draft.invoice_number, invoice_line_items_attributes: lines
      )
    }, headers: auth_headers(extraction_super_admin)
  end

  # The entries Timekeeping holds a reservation for, read from Timekeeping
  # itself: its locked field is set exactly when a reservation row exists.
  def extraction_reserved_ids(company, entries)
    entries.map(&:id).select { |id| extraction_timekeeping_entry(company, id).fetch("locked") }
  end

  # nil while Timekeeping is fenced. Read from the Timekeeping database
  # directly, because no route answers it.
  def extraction_timekeeping_admitted_generation
    url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    connection = TimekeepingDatabaseReset.connect(url, TimekeepingDatabaseReset.database_name(url))
    connection.exec_params("SELECT generation FROM admission WHERE id = $1", [TimekeepingDatabaseReset::ADMISSION_ID])
      .getvalue(0, 0)
  ensure
    connection&.close
  end

  # The company's project with the most kept entries, lowest id on a tie.
  def extraction_busiest_project_id(company)
    TimesheetEntry.kept.in_workspace(company).group(:project_id)
      .order(Arel.sql("COUNT(*) DESC"), :project_id).limit(1).pluck(:project_id).first
  end

  def extraction_row_counts(checkpoint)
    checkpoint.rows.transform_values(&:size)
  end

  # The member with the most entries in the company, the span of the company's
  # entries, and noon on the last day that holds one, so every reader's date
  # window covers seeded entries.
  def extraction_report_context(company)
    entries = TimesheetEntry.kept.in_workspace(company)
    member = User.find(entries.group(:user_id).order(Arel.sql("COUNT(*) DESC")).limit(1).pluck(:user_id).first)
    from, to = entries.pick(Arel.sql("MIN(work_date)"), Arel.sql("MAX(work_date)"))
    NotificationPreference.find_or_create_by!(user: member, company:)
    { company:, member:, from:, to:, day: to.in_time_zone.noon }.freeze
  end

  # Whether the weekly reminder would mail the member for the week of the
  # context's last entry. The reminder records the week it mailed, so the
  # check runs in a transaction that is rolled back and a later read sees the
  # same state.
  def extraction_weekly_reminders(context)
    reminded = nil
    travel_to(context[:day] + 1.week) do
      ActiveRecord::Base.transaction do
        enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.size
        WeeklyReminderForMissedEntriesService.new.check_entries_and_send_mail(context[:member], context[:company])
        reminded = ActiveJob::Base.queue_adapter.enqueued_jobs.size > enqueued
        raise ActiveRecord::Rollback
      end
    end
    [[context[:member].id, reminded]]
  end

  # A seeded entry whose user owns no company, so the sole-owner refusal,
  # which the controller checks first, cannot answer in place of the handoff
  # refusal.
  def extraction_seeded_non_owner_entry(company)
    owner_ids = Role.where(name: "owner", resource_type: "Company").joins(:users).pluck("users.id")
    TimesheetEntry.unscoped.joins(project: :client)
      .where(clients: { company_id: company.id })
      .where.not(user_id: owner_ids)
      .order(:id)
      .first!
  end
end

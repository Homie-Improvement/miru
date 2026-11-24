# frozen_string_literal: true

require "rails_helper"
require "json"
require "net/http"
require "securerandom"
require "yaml"

# Live proofs that an interrupted handoff can be resumed or aborted. The
# :integrated_runtime tag skips every group unless the live flag is set
# (spec/support/timekeeping/integrated_runtime.rb), so the default suite skips
# them, and a skip is not a pass.
#
# The same tag turns on the queue ledger
# (spec/support/timekeeping/queue_ledger.rb), so a job any runtime worker runs
# from a non-dedicated queue fails the suite at teardown. The ledger reads only
# Solid Queue rows and cannot see the jobs Timekeeping::Handoff::Runner
# performs inline, such as its relay drain, so every group also carries
# :inline_jobs_on_dedicated_queues, whose hook fails an example in which any
# job ran inline on a queue that is not dedicated on the monolith.
RSpec.describe "Timekeeping interrupted handoff", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  # "On resume each queued snapshot is applied exactly once, shown by delivery receipts, and reconciliation passes; a second resume changes nothing"
  # "Reconciliation and money checks pass after each resumed or aborted handoff, on each seeded company"
  it "resume after a before_freeze interrupt applies each queued snapshot exactly once, reconciles and keeps money, and a second resume changes nothing" do
    WebMock.disable_net_connect!(allow_localhost: true)
    companies = [fork_and_leaf, copper_kettle]
    company_ids = companies.map(&:id)
    runner = Timekeeping::Handoff::Runner
    no_wait = ->(_seconds) { raise "a resume must never wait" }
    create_entry = lambda do |company|
      user = company.users.order(:id).find do |candidate|
        candidate.token.present? && candidate.current_workspace_id == company.id && candidate.employed_at?(company.id) &&
          (candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company))
      end
      project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first
      uri = URI.join(@integrated_runtime.monolith_url, "/api/v1/timesheet_entry")
      request = Net::HTTP::Post.new(uri)
      request["X-Auth-Email"] = user.email
      request["X-Auth-Token"] = user.token
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(project_id: project.id, timesheet_entry: {
                                     duration: 60, work_date: Date.current.iso8601, note: "Interrupted", bill_status: "unbilled"
                                   })
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      expect(response.code).to eq("200"), "entry create answered #{response.code}"
    end
    state = lambda do
      ActiveRecord::Base.uncached do
        {
          projection: company_ids.index_with do |id|
            ActiveRecord::Base.connection.select_all(
              "SELECT * FROM timesheet_entries WHERE company_id = $1 ORDER BY id", "interrupted", [id]
            ).to_a
          end,
          receipts: ActiveRecord::Base.connection.select_rows("SELECT * FROM entry_snapshot_receipts ORDER BY id"),
          outbox: TimekeepingLiveHandoff.with_timekeeping_database do |connection|
            connection.exec("SELECT outbox_position, sent_at FROM outbox_snapshots ORDER BY outbox_position").values
          end,
          ownership: TimekeepingLiveHandoff.ownership_row_text(ActiveRecord::Base.connection.raw_connection),
          money: company_ids.index_with { |id| TimekeepingLiveHandoff.money(company_id: id) }
        }
      end
    end

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| 2.times { create_entry.call(company) } }

      queued = TimekeepingLiveHandoff.with_timekeeping_database do |connection|
        company_ids.sum { |id| TimekeepingLiveHandoff.queued_positions(connection, company_id: id).size }
      end
      expect(queued).to be >= 4
      baseline = ActiveRecord::Base.uncached { EntrySnapshotReceipt.maximum(:id) || 0 }
      money_before = company_ids.index_with { |id| TimekeepingLiveHandoff.money(company_id: id) }
      report_root = live_handoff_report_root

      expect do
        runner.run(direction: :rollback, report_root:, sleeper: no_wait,
                   observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)

      live_handoff_resume_relay
      expect(runner.run(direction: :rollback, resume: true, report_root:, sleeper: no_wait)).to be_nil

      receipts = ActiveRecord::Base.uncached { EntrySnapshotReceipt.order(:id).to_a }
      expect(TimekeepingLiveHandoff.applied_since(receipts, baseline_id: baseline)).to eq(applied: queued, ignored: 0)

      # Receipt sums cannot show a wrong final row, so the projection is also
      # compared with the outgoing Timekeeping store, company by company.
      entry_columns = "id, note, duration::float8::text, work_date::text, project_id, user_id"
      company_ids.each do |id|
        outgoing = TimekeepingLiveHandoff.with_timekeeping_database do |connection|
          connection.exec_params("SELECT #{entry_columns} FROM entries WHERE company_id = $1 ORDER BY id", [id]).values
        end
        projected = ActiveRecord::Base.connection.raw_connection.exec_params(
          "SELECT #{entry_columns} FROM timesheet_entries WHERE company_id = $1 AND id = ANY($2::bigint[]) ORDER BY id",
          [id, PG::TextEncoder::Array.new.encode(outgoing.map(&:first))]
        ).values
        expect(projected).to eq(outgoing), "projection rows of company #{id} differ from the outgoing store"
      end

      generation = TimekeepingOwnership.uncached do
        TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:generation)
      end
      report = JSON.parse(File.read(report_root.join("generation-#{generation}", "reconciliation.json")))
      expect(LiveHandoff.reconciliation_failures(report, company_ids:)).to eq([])
      company_ids.each do |id|
        expect(Timekeeping::FinancialSnapshot.compare(money_before.fetch(id), TimekeepingLiveHandoff.money(company_id: id)))
          .to eq([]), "money of company #{id} changed"
      end

      before_second = state.call
      # The handoff already flipped to the monolith, so the runner runs no step
      # and only re-sends the monolith's admit call (Steps.decide_idle); the
      # comparison below is the proof it changed nothing.
      expect(runner.run(direction: :rollback, resume: true, report_root:, sleeper: no_wait)).to be_nil
      expect(state.call).to eq(before_second)
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  # "While the relay is paused an abort leaves the ownership row and admission unchanged; once it resumes the abort completes, queued snapshots reach the projection before writes reopen, a later write's snapshot arrives, the prior owner returns and the money snapshot is unchanged"
  it "abort while the relay is paused keeps the row fenced, then returns the prior owner with money unchanged on each company" do
    WebMock.disable_net_connect!(allow_localhost: true)
    companies = [fork_and_leaf, copper_kettle]
    company_ids = companies.map(&:id)
    runner = Timekeeping::Handoff::Runner
    no_wait = ->(_seconds) { raise "a resume must never wait" }
    poll_cap_error = Class.new(StandardError)
    create_entry = lambda do |company|
      user = company.users.order(:id).find do |candidate|
        candidate.token.present? && candidate.current_workspace_id == company.id && candidate.employed_at?(company.id) &&
          (candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company))
      end
      project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first
      uri = URI.join(@integrated_runtime.monolith_url, "/api/v1/timesheet_entry")
      request = Net::HTTP::Post.new(uri)
      request["X-Auth-Email"] = user.email
      request["X-Auth-Token"] = user.token
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(project_id: project.id, timesheet_entry: {
                                     duration: 60, work_date: Date.current.iso8601, note: "Interrupted", bill_status: "unbilled"
                                   })
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      expect(response.code).to eq("200"), "entry create answered #{response.code}"
      Integer(JSON.parse(response.body).dig("entry", "id"))
    end
    row_text = -> { TimekeepingLiveHandoff.ownership_row_text(ActiveRecord::Base.connection.raw_connection) }

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| create_entry.call(company) }
      money_before = company_ids.index_with { |id| TimekeepingLiveHandoff.money(company_id: id) }
      report_root = live_handoff_report_root

      expect do
        runner.run(direction: :rollback, report_root:, sleeper: no_wait,
                   observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      # The paused resume stores P and is refused at freeze, so the abort that
      # follows has no P left to write and the row must stay as it is.
      expect do
        runner.run(direction: :rollback, resume: true, report_root:, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)

      row_before_abort = row_text.call
      final_position = Integer(JSON.parse(row_before_abort).fetch("final_outbox_position"))
      queued_at_or_below_p = TimekeepingLiveHandoff.with_timekeeping_database do |connection|
        company_ids.flat_map { |id| TimekeepingLiveHandoff.queued_positions(connection, company_id: id) }
                   .select { |position| position <= final_position }
      end
      expect(queued_at_or_below_p).not_to be_empty

      paused_rows = []
      polls = 0
      sleeper = lambda do |_seconds|
        polls += 1
        raise poll_cap_error, "the abort was still waiting after 10 polls" if polls > 10

        if polls == 1
          paused_rows << row_text.call
        elsif polls == 2
          live_handoff_resume_relay
        end
      end
      expect(runner.run(direction: :rollback, abort: true, report_root:, sleeper:)).to be_nil

      expect(polls).to be >= 2
      expect(paused_rows).to eq([row_before_abort])
      owner = TimekeepingOwnership.uncached do
        TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:owner, :handoff_step)
      end
      expect(owner).to eq(["timekeeping", nil])
      company_ids.each do |id|
        expect(Timekeeping::FinancialSnapshot.compare(money_before.fetch(id), TimekeepingLiveHandoff.money(company_id: id)))
          .to eq([]), "money of company #{id} changed"
      end
      reconciliation = live_handoff_aborted_reconciliation(report_root)
      expect(reconciliation.abort?).to be(false), reconciliation.to_h.inspect

      later_entry = create_entry.call(companies.first)
      live_handoff_catch_up!
      projected = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM timesheet_entries WHERE company_id = $1 AND id = $2", "interrupted",
          [companies.first.id, later_entry]
        ).to_i
      end
      expect(projected).to eq(1)
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff, resumed from before_freeze", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def ih_resume_owner_of(company)
    User.with_role(:owner, company).order(:id).find { |user| user.token.present? } ||
      raise("#{company.name} has no seeded owner with an API token")
  end

  def ih_resume_write(company, method:, path:, body:)
    user = ih_resume_owner_of(company)
    headers = { "X-Auth-Email" => user.email, "X-Auth-Token" => user.token,
                "Idempotency-Key" => "ih-resume-#{SecureRandom.hex(8)}" }
    reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, { method:, path:, headers:, body: })
    expect(reply.status).to eq(200), "#{method} #{path} answered #{reply.status}: #{reply.body}"
    JSON.parse(reply.body)
  end

  # Two versions of one entry plus a single edit of another, for one company.
  def ih_resume_queue_writes(company)
    project = company.projects.kept.order(:id).first
    created = ih_resume_write(company, method: "POST", path: "/api/v1/timesheet_entry",
                                       body: { "project_id" => project.id,
                                               "timesheet_entry" => { "duration" => 30.0, "note" => "ih v1",
                                                                      "work_date" => Date.current.iso8601 } })
    entry_id = created.fetch("entry").fetch("id")
    ih_resume_write(company, method: "PUT", path: "/api/v1/timesheet_entry/#{entry_id}",
                             body: { "project_id" => project.id,
                                     "timesheet_entry" => { "duration" => 45.0, "note" => "ih v2" } })
    ih_resume_write(company, method: "POST", path: "/api/v1/timesheet_entry",
                             body: { "project_id" => project.id,
                                     "timesheet_entry" => { "duration" => 15.0, "note" => "ih other",
                                                            "work_date" => Date.current.iso8601 } })
  end

  def ih_resume_queued_positions(companies)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      companies.flat_map { |company| TimekeepingLiveHandoff.queued_positions(connection, company_id: company.id) }
    end
  end

  def ih_resume_receipts_above(baseline_id)
    ActiveRecord::Base.uncached { EntrySnapshotReceipt.where("id > ?", baseline_id).order(:id).to_a }
  end

  it "a rollback interrupted at before_freeze with snapshots queued resumes, applying each queued snapshot exactly once with reconciliation passing" do
    no_wait = ->(_seconds) { raise "a resume must never wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| ih_resume_queue_writes(company) }

      money_before = companies.to_h { |company| [company.id, TimekeepingLiveHandoff.money(company_id: company.id)] }
      queued = ih_resume_queued_positions(companies)
      # Two versions of one entry plus one other entry, for each of the two companies.
      expect(queued.size).to eq(6)
      receipt_baseline = ActiveRecord::Base.uncached { EntrySnapshotReceipt.maximum(:id) || 0 }

      recorded_at_interrupt = []
      interrupt = TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze)
      observer = lambda do |event, step:|
        recorded_at_interrupt << ih_resume_queued_positions(companies).size if event == :before_step && step.to_s == "freeze"
        interrupt.call(event, step:)
      end
      rollback_root = live_handoff_report_root

      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, observer:, report_root: rollback_root, sleeper: no_wait)
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      # "At `before_freeze`, P is not stored yet and snapshots are queued. Assert, inside the observer, that the queued count is above zero."
      expect(recorded_at_interrupt.size).to eq(1)
      expect(recorded_at_interrupt.first).to be > 0

      # "A run with the relay paused stores P and is refused at freeze. This is the design's "after step 3" point. Assert that snapshots at or below P are still queued."
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: rollback_root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      final_position = ActiveRecord::Base.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).final_outbox_position }
      expect(final_position).not_to be_nil
      expect(queued.max).to be <= final_position
      expect(ih_resume_queued_positions(companies)).to match_array(queued)

      live_handoff_resume_relay
      expect(Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: rollback_root, sleeper: no_wait)).to be_nil

      # "Exactly-once: read the `EntrySnapshotReceipt` rows written after the interrupt. The sum of their `"applied"` counts must equal the queued count."
      receipts = ih_resume_receipts_above(receipt_baseline)
      expect(TimekeepingLiveHandoff.applied_since(receipts, baseline_id: receipt_baseline))
        .to eq(applied: queued.size, ignored: 0)
      expect(ih_resume_queued_positions(companies)).to eq([])

      ownership = ActiveRecord::Base.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
      expect(ownership.owner).to eq("monolith")
      expect(ownership.handoff_step).to be_nil

      # "A resumed run's reconciliation: read `generation-N/reconciliation.json` under that run's own `report_root`."
      reports = Dir.glob(rollback_root.join("generation-*", "reconciliation.json").to_s)
      expect(reports.size).to eq(1)
      report = JSON.parse(File.read(reports.first))
      expect(LiveHandoff.reconciliation_failures(report, company_ids: companies.map(&:id))).to eq([])

      # "Compare money for each company separately."
      companies.each do |company|
        after = TimekeepingLiveHandoff.money(company_id: company.id)
        expect(Timekeeping::FinancialSnapshot.compare(money_before.fetch(company.id), after)).to eq([]), company.name
      end
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff, interrupted at during_checkpoint", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def ih_checkpoint_create(company, note:)
    user = User.with_role(:owner, company).order(:id).find { |candidate| candidate.token.present? }
    project = company.projects.kept.order(:id).first
    headers = { "X-Auth-Email" => user.email, "X-Auth-Token" => user.token,
                "Idempotency-Key" => "ih-checkpoint-#{SecureRandom.hex(8)}" }
    reply = LiveHandoff.send_request(
      @integrated_runtime.monolith_url,
      { method: "POST", path: "/api/v1/timesheet_entry", headers:,
        body: { "project_id" => project.id,
                "timesheet_entry" => { "duration" => 30.0, "note" => note, "work_date" => Date.current.iso8601 } } }
    )
    expect(reply.status).to eq(200), "entry create answered #{reply.status}: #{reply.body}"
    JSON.parse(reply.body).fetch("entry").fetch("id")
  end

  def ih_checkpoint_queued(companies)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      companies.flat_map { |company| TimekeepingLiveHandoff.queued_positions(connection, company_id: company.id) }
    end
  end

  def ih_checkpoint_projected_ids(entry_ids)
    ActiveRecord::Base.uncached { TimesheetEntry.unscoped.where(id: entry_ids).pluck(:id) }
  end

  it "a rollback reaches during_checkpoint only with the queue empty and the projection holding each queued snapshot" do
    no_wait = ->(_seconds) { raise "a resume must never wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      entry_ids = companies.flat_map { |company| 2.times.map { |n| ih_checkpoint_create(company, note: "ih cp #{n}") } }
      queued = ih_checkpoint_queued(companies)
      expect(queued.size).to eq(entry_ids.size)
      expect(ih_checkpoint_projected_ids(entry_ids)).to eq([])
      company_ids = companies.map(&:id)
      money_before = company_ids.index_with { |id| TimekeepingLiveHandoff.money(company_id: id) }

      rollback_root = live_handoff_report_root
      interrupt = TimekeepingHandoffHooks::Interrupt.new(at: :during_checkpoint)
      at_checkpoint = []
      observer = lambda do |event, step:|
        if event == :during_checkpoint
          at_checkpoint << { queued: ih_checkpoint_queued(companies), projected: ih_checkpoint_projected_ids(entry_ids) }
        end
        interrupt.call(event, step:)
      end

      # With the relay paused the freeze drain cannot finish, so the run is refused before checkpoint.
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, observer:, report_root: rollback_root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      expect(at_checkpoint).to eq([])

      # Taken before the relay resumes, so every receipt above it is from this resume's delivery.
      receipt_baseline = ActiveRecord::Base.uncached { EntrySnapshotReceipt.maximum(:id) || 0 }
      live_handoff_resume_relay
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, observer:, report_root: rollback_root,
                                         sleeper: no_wait)
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)

      # "`during_checkpoint` is reached only after the relay resumes and the queue through P drains. Assert that the queue is empty and that the projection holds each queued position."
      expect(at_checkpoint.size).to eq(1)
      expect(at_checkpoint.first.fetch(:queued)).to eq([])
      expect(at_checkpoint.first.fetch(:projected)).to match_array(entry_ids)

      # "Exactly-once: read the `EntrySnapshotReceipt` rows written after the interrupt. The sum of their `"applied"` counts must equal the queued count."
      receipts = ActiveRecord::Base.uncached { EntrySnapshotReceipt.order(:id).to_a }
      expect(TimekeepingLiveHandoff.applied_since(receipts, baseline_id: receipt_baseline))
        .to eq(applied: queued.size, ignored: 0)

      expect(Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: rollback_root,
                                              sleeper: no_wait)).to be_nil
      ownership = ActiveRecord::Base.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
      expect(ownership.owner).to eq("monolith")

      # "Reconciliation and money checks pass after each resumed or aborted handoff, on each seeded company"
      report = JSON.parse(File.read(rollback_root.join("generation-#{ownership.generation}", "reconciliation.json")))
      expect(LiveHandoff.reconciliation_failures(report, company_ids:)).to eq([])
      company_ids.each do |id|
        expect(Timekeeping::FinancialSnapshot.compare(money_before.fetch(id), TimekeepingLiveHandoff.money(company_id: id)))
          .to eq([]), "money of company #{id} changed"
      end
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff, aborted while paused", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  # Wraps the outgoing owner's admission so on_admit runs at the moment it
  # reopens writes, before it reopens them.
  def ih_abort_recording_admission(admission, on_admit)
    Class.new(SimpleDelegator) do
      define_method(:admit) do |generation:|
        on_admit.call
        __getobj__.admit(generation:)
      end
    end.new(admission)
  end

  def ih_abort_owner_of(company)
    User.with_role(:owner, company).order(:id).find { |user| user.token.present? }
  end

  def ih_abort_send(company, method:, path:, body:)
    user = ih_abort_owner_of(company)
    headers = { "X-Auth-Email" => user.email, "X-Auth-Token" => user.token,
                "Idempotency-Key" => "ih-abort-#{SecureRandom.hex(8)}" }
    LiveHandoff.send_request(@integrated_runtime.monolith_url, { method:, path:, headers:, body: })
  end

  def ih_abort_create(company, note:)
    project = company.projects.kept.order(:id).first
    reply = ih_abort_send(company, method: "POST", path: "/api/v1/timesheet_entry",
                                   body: { "project_id" => project.id,
                                           "timesheet_entry" => { "duration" => 30.0, "note" => note,
                                                                  "work_date" => Date.current.iso8601 } })
    expect(reply.status).to eq(200), "entry create answered #{reply.status}: #{reply.body}"
    JSON.parse(reply.body).fetch("entry").fetch("id")
  end

  def ih_abort_projected_ids(entry_ids)
    ActiveRecord::Base.uncached { TimesheetEntry.unscoped.where(id: entry_ids).pluck(:id) }
  end

  def ih_abort_row_text
    TimekeepingLiveHandoff.ownership_row_text(ActiveRecord::Base.connection.raw_connection)
  end

  it "an abort while the relay is paused holds the row and admission, then completes once the relay resumes, delivering queued snapshots before the prior owner readmits" do
    no_wait = ->(_seconds) { raise "a resume must never wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      entry_ids = companies.map { |company| ih_abort_create(company, note: "ih abort queued") }
      money_before = companies.to_h { |company| [company.id, TimekeepingLiveHandoff.money(company_id: company.id)] }
      rollback_root = live_handoff_report_root

      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze),
                                         report_root: rollback_root, sleeper: no_wait)
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      # P is stored by a paused resume refused at freeze, so the abort itself does not write P.
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: rollback_root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      row_before_abort = ih_abort_row_text

      polls = []
      projected_at_admit = []
      owners = Timekeeping::Handoff::Runner.configured_owners
      outgoing = owners.fetch("timekeeping")
      owners["timekeeping"] = outgoing.with(
        admission: ih_abort_recording_admission(outgoing.admission, -> { projected_at_admit << ih_abort_projected_ids(entry_ids) })
      )
      poll_cap = 10
      paused_sleeper = lambda do |_seconds|
        raise "the abort was still waiting after #{poll_cap} polls" if polls.size >= poll_cap

        project = fork_and_leaf.projects.kept.order(:id).first
        billing = ih_abort_send(fork_and_leaf, method: "POST", path: "/api/v1/invoices",
                                               body: { "invoice" => { "client_id" => project.client_id, "status" => "draft",
                                                                      "invoice_number" => "IH-#{SecureRandom.hex(4)}",
                                                                      "issue_date" => Date.current.iso8601,
                                                                      "due_date" => 30.days.from_now.to_date.iso8601 } })
        polls << { row: ih_abort_row_text, billing_status: billing.status,
                   billing_reason: JSON.parse(billing.body)["reason"], projected: ih_abort_projected_ids(entry_ids) }
        live_handoff_resume_relay if polls.size == 2
      end

      expect(Timekeeping::Handoff::Runner.run(direction: :rollback, abort: true, owners:, report_root: rollback_root,
                                              sleeper: paused_sleeper)).to be_nil

      # "While the relay is paused an abort leaves the ownership row and admission unchanged"
      expect(polls.size).to be >= 2
      paused_polls = polls.first(2)
      expect(paused_polls.pluck(:row)).to all(eq(row_before_abort))
      expect(paused_polls.pluck(:billing_status)).to all(eq(503))
      expect(paused_polls.pluck(:billing_reason)).to all(eq("ownership_moving"))
      expect(paused_polls.first[:projected]).to eq([])

      # "every queued position at or below P is in the projection before the outgoing owner admits writes"
      expect(projected_at_admit.size).to eq(1)
      expect(projected_at_admit.first).to match_array(entry_ids)

      ownership = ActiveRecord::Base.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
      expect(ownership.owner).to eq("timekeeping")
      expect(ownership.handoff_step).to be_nil

      reconciliation = live_handoff_aborted_reconciliation(rollback_root)
      expect(reconciliation.abort?).to be(false), reconciliation.to_h.inspect

      later_id = ih_abort_create(fork_and_leaf, note: "ih abort later")
      live_handoff_catch_up!
      expect(ih_abort_projected_ids([later_id])).to eq([later_id])

      companies.each do |company|
        after = TimekeepingLiveHandoff.money(company_id: company.id)
        expect(Timekeeping::FinancialSnapshot.compare(money_before.fetch(company.id), after)).to eq([]), company.name
      end
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff: paused abort", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def paused_abort_admin(company)
    company.users.order(:id).find do |user|
      user.token.present? && user.current_workspace_id == company.id && user.employed_at?(company.id) &&
        (user.has_role?(:owner, company) || user.has_role?(:admin, company))
    end || raise("#{company.name} has no seeded owner or admin with an API token")
  end

  def paused_abort_post(path, user:, body:)
    uri = URI.join(@integrated_runtime.monolith_url, path)
    request = Net::HTTP::Post.new(uri)
    request["X-Auth-Email"] = user.email
    request["X-Auth-Token"] = user.token
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  def paused_abort_create_entry(company)
    project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
    response = paused_abort_post(
      "/api/v1/timesheet_entry", user: paused_abort_admin(company),
      body: { project_id: project.id,
              timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Interrupted", bill_status: "unbilled" } }
    )
    expect(response.code).to eq("200"), "entry create answered #{response.code}: #{response.body}"
  end

  def paused_abort_billing_answer(company)
    client = company.clients.kept.order(:id).first!
    response = paused_abort_post(
      "/api/v1/invoices", user: paused_abort_admin(company),
      body: { invoice: { client_id: client.id, invoice_number: "PAUSED-ABORT-#{company.id}-#{SecureRandom.hex(4)}",
                         issue_date: Date.current.iso8601, due_date: (Date.current + 7).iso8601, status: "draft",
                         currency: company.base_currency,
                         invoice_line_items_attributes: [
                           { name: "Work", description: "Work", date: Date.current.iso8601, rate: 100, quantity: 60 }
                         ] } }
    )
    [response.code, JSON.parse(response.body)["reason"]]
  end

  def paused_abort_ownership_text
    TimekeepingLiveHandoff.ownership_row_text(ActiveRecord::Base.connection.raw_connection)
  end

  it "an abort started while the relay is paused, after a paused resume stored P, keeps the ownership row byte-identical and billing writes refused on every paused poll" do
    unexpected_wait = Class.new(StandardError)
    poll_cap_passed = Class.new(StandardError)
    no_wait = ->(_seconds) { raise unexpected_wait, "a resume or forward run started to wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| paused_abort_create_entry(company) }

      root = live_handoff_report_root
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, report_root: root, sleeper: no_wait,
                                         observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)

      # An abort with P unset would write P itself, so a paused resume stores P first and is refused at freeze.
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      row_before_abort = paused_abort_ownership_text

      paused_rows = []
      paused_billing = []
      polls = 0
      sleeper = lambda do |_seconds|
        polls += 1
        raise poll_cap_passed, "the abort was still waiting after 10 polls" if polls > 10
        next unless TimekeepingLiveHandoff.pause_file.exist?

        paused_rows << paused_abort_ownership_text
        paused_billing.concat(companies.map { |company| paused_abort_billing_answer(company) })
        live_handoff_resume_relay if polls == 2
      end

      Timekeeping::Handoff::Runner.run(direction: :rollback, abort: true, report_root: root, sleeper:)

      # "While the relay is paused an abort leaves the ownership row and admission unchanged"
      expect(paused_rows.size).to be >= 2
      expect(paused_rows).to all(eq(row_before_abort))
      # "While paused, the abort leaves owner, `handoff_step`, generation and `final_outbox_position` unchanged, and a billing write still answers `503 ownership_moving`."
      expect(paused_billing).to all(eq(%w[503 ownership_moving]))
      owner = TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
      expect([owner.owner, owner.handoff_step]).to eq(["timekeeping", nil])
      reconciliation = live_handoff_aborted_reconciliation(root)
      expect(reconciliation.abort?).to be(false), reconciliation.to_h.inspect
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff: abort ordering", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def abort_ordering_admin(company)
    company.users.order(:id).find do |user|
      user.token.present? && user.current_workspace_id == company.id && user.employed_at?(company.id) &&
        (user.has_role?(:owner, company) || user.has_role?(:admin, company))
    end || raise("#{company.name} has no seeded owner or admin with an API token")
  end

  def abort_ordering_write(company, method:, path:, body:)
    user = abort_ordering_admin(company)
    headers = { "X-Auth-Email" => user.email, "X-Auth-Token" => user.token,
                "Idempotency-Key" => "abort-ordering-#{SecureRandom.hex(8)}" }
    reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, { method:, path:, headers:, body: })
    expect(reply.status).to eq(200), "#{method} #{path} answered #{reply.status}: #{reply.body}"
    JSON.parse(reply.body)
  end

  def abort_ordering_create_entry(company, project:, note:)
    created = abort_ordering_write(company, method: "POST", path: "/api/v1/timesheet_entry",
                                            body: { "project_id" => project.id,
                                                    "timesheet_entry" => { "duration" => 60.0, "note" => note,
                                                                           "bill_status" => "unbilled",
                                                                           "work_date" => Date.current.iso8601 } })
    Integer(created.dig("entry", "id"))
  end

  # Queues, for one company, two versions of one entry plus single writes of
  # two other entries, so a projection holding only the first version of the
  # edited entry can be told apart from one holding every latest version.
  # Returns { edited:, others: } entry ids.
  def abort_ordering_queue_writes(company)
    project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
    edited = abort_ordering_create_entry(company, project:, note: "abort ordering #{company.id} v1")
    abort_ordering_write(company, method: "PUT", path: "/api/v1/timesheet_entry/#{edited}",
                                  body: { "project_id" => project.id,
                                          "timesheet_entry" => { "duration" => 45.0, "note" => "abort ordering #{company.id} v2" } })
    others = %w[other-b other-c].map do |label|
      abort_ordering_create_entry(company, project:, note: "abort ordering #{company.id} #{label}")
    end
    { edited:, others: }
  end

  # The projection's version and note of each given entry, read uncached
  # because runtime processes write these rows outside this connection.
  def abort_ordering_projected_snapshots(ids)
    encoded_ids = PG::TextEncoder::Array.new.encode(ids.map { |id| Integer(id) })
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_rows(
        "SELECT id, version, note FROM timesheet_entries WHERE id = ANY($1::bigint[])", "abort ordering", [encoded_ids]
      ).to_h { |id, version, note| [Integer(id), { version: Integer(version), note: }] }
    end
  end

  it "the before_freeze abort admits the outgoing owner only once every queued entry is already in the projection" do
    unexpected_wait = Class.new(StandardError)
    poll_cap_passed = Class.new(StandardError)
    no_wait = ->(_seconds) { raise unexpected_wait, "a resume or forward run started to wait" }

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies = [fork_and_leaf, copper_kettle]
      queued = companies.to_h { |company| [company.id, abort_ordering_queue_writes(company)] }
      queued_ids = queued.values.flat_map { |entries| [entries.fetch(:edited), *entries.fetch(:others)] }

      # Taken from the outgoing store before the rollback, never from the
      # projection the admit record is compared with.
      expected_at_admit = TimekeepingLiveHandoff.with_timekeeping_database do |connection|
        queued.each do |company_id, entries|
          expect(TimekeepingLiveHandoff.queued_count(connection, company_id:, entry_id: entries.fetch(:edited))).to eq(2)
          entries.fetch(:others).each do |entry_id|
            expect(TimekeepingLiveHandoff.queued_count(connection, company_id:, entry_id:)).to eq(1)
          end
        end
        TimekeepingLiveHandoff.latest_queued_snapshots(connection, entry_ids: queued_ids)
      end
      expect(expected_at_admit.keys).to match_array(queued_ids)
      queued.each_value do |entries|
        expect(expected_at_admit.fetch(entries.fetch(:edited))[:note]).to end_with(" v2")
      end
      projected_before = abort_ordering_projected_snapshots(queued_ids)
      expect(projected_before.select { |id, snapshot| expected_at_admit.fetch(id) == snapshot }).to be_empty

      root = live_handoff_report_root
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, report_root: root, sleeper: no_wait,
                                         observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)

      projected_at_admit = []
      # A lambda, because the admit method below runs on the delegator, which
      # cannot call this example group's helpers.
      record_projection = -> { projected_at_admit << abort_ordering_projected_snapshots(queued_ids) }
      configured = Timekeeping::Handoff::Runner.configured_owners
      timekeeping = configured.fetch("timekeeping")
      recording_admission = Class.new(SimpleDelegator) do
        define_method(:admit) do |**kwargs|
          record_projection.call
          __getobj__.admit(**kwargs)
        end
      end.new(timekeeping.admission)
      owners = configured.merge("timekeeping" => timekeeping.with(admission: recording_admission))

      polls = 0
      sleeper = lambda do |_seconds|
        polls += 1
        raise poll_cap_passed, "the abort was still waiting after 10 polls" if polls > 10

        live_handoff_resume_relay if polls == 2
      end
      Timekeeping::Handoff::Runner.run(direction: :rollback, abort: true, owners:, report_root: root, sleeper:)

      # "every queued position at or below P is in the projection before the outgoing owner admits writes"
      expect(polls).to be >= 2
      expect(projected_at_admit.size).to eq(1)
      expect(projected_at_admit.first.keys).to match_array(queued_ids)
      # Ids alone would pass with only the edited entry's first version
      # applied; the version and note show the latest queued one arrived.
      expect(projected_at_admit.first).to eq(expected_at_admit)
      reconciliation = live_handoff_aborted_reconciliation(root)
      expect(reconciliation.abort?).to be(false), reconciliation.to_h.inspect
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff: queue at before_freeze", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def queue_state_create_entry(company)
    user = company.users.order(:id).find do |candidate|
      candidate.token.present? && candidate.current_workspace_id == company.id && candidate.employed_at?(company.id) &&
        (candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company))
    end || raise("#{company.name} has no seeded owner or admin with an API token")
    project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
    uri = URI.join(@integrated_runtime.monolith_url, "/api/v1/timesheet_entry")
    request = Net::HTTP::Post.new(uri)
    request["X-Auth-Email"] = user.email
    request["X-Auth-Token"] = user.token
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      project_id: project.id,
      timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Interrupted", bill_status: "unbilled" }
    )
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    expect(response.code).to eq("200"), "entry create answered #{response.code}: #{response.body}"
  end

  def queue_state_positions(companies)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      companies.flat_map { |company| TimekeepingLiveHandoff.queued_positions(connection, company_id: company.id) }.sort
    end
  end

  it "a rollback interrupted at before_freeze still has snapshots queued, and a paused resume refused at freeze leaves every position at or below P queued" do
    unexpected_wait = Class.new(StandardError)
    no_wait = ->(_seconds) { raise unexpected_wait, "a resume or forward run started to wait" }
    companies = [fork_and_leaf, copper_kettle]
    interrupt = TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze)
    queued_at_interrupt = []
    observer = lambda do |event, step:|
      queued_at_interrupt << queue_state_positions(companies) if event.to_s == "before_step" && step.to_s == "freeze"
      interrupt.call(event, step:)
    end

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| 2.times { queue_state_create_entry(company) } }

      root = live_handoff_report_root
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, report_root: root, sleeper: no_wait, observer:)
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)

      # "At `before_freeze`, P is not stored yet and snapshots are queued. Assert, inside the observer, that the queued count is above zero."
      expect(queued_at_interrupt.size).to eq(1)
      expect(queued_at_interrupt.first.size).to be >= 4
      expect(TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
                                 .final_outbox_position).to be_nil

      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)

      final_position = TimekeepingOwnership.uncached do
        TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).final_outbox_position
      end
      # "A run with the relay paused stores P and is refused at freeze. This is the design's "after step 3" point. Assert that snapshots at or below P are still queued."
      expect(final_position).to be >= queued_at_interrupt.first.max
      expect(queue_state_positions(companies).select { |position| position <= final_position })
        .to eq(queued_at_interrupt.first)
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff: second resume", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def second_resume_create_entry(company)
    user = company.users.order(:id).find do |candidate|
      candidate.token.present? && candidate.current_workspace_id == company.id && candidate.employed_at?(company.id) &&
        (candidate.has_role?(:owner, company) || candidate.has_role?(:admin, company))
    end || raise("#{company.name} has no seeded owner or admin with an API token")
    project = Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
    uri = URI.join(@integrated_runtime.monolith_url, "/api/v1/timesheet_entry")
    request = Net::HTTP::Post.new(uri)
    request["X-Auth-Email"] = user.email
    request["X-Auth-Token"] = user.token
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      project_id: project.id,
      timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Interrupted", bill_status: "unbilled" }
    )
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    expect(response.code).to eq("200"), "entry create answered #{response.code}: #{response.body}"
  end

  def second_resume_state(companies)
    connection = ActiveRecord::Base.connection
    outbox = TimekeepingLiveHandoff.with_timekeeping_database do |timekeeping|
      timekeeping.exec("SELECT outbox_position, sent_at IS NOT NULL FROM outbox_snapshots ORDER BY outbox_position").values
    end
    ActiveRecord::Base.uncached do
      {
        projection: connection.select_rows("SELECT * FROM timesheet_entries ORDER BY id"),
        receipts: connection.select_rows("SELECT * FROM entry_snapshot_receipts ORDER BY id"),
        outbox:,
        ownership: TimekeepingLiveHandoff.ownership_row_text(connection.raw_connection),
        money: companies.to_h { |company| [company.id, TimekeepingLiveHandoff.money(company_id: company.id).to_h] }
      }
    end
  end

  it "a second resume after a completed resumed rollback changes no projection row, receipt, outbox position, ownership row or money" do
    unexpected_wait = Class.new(StandardError)
    no_wait = ->(_seconds) { raise unexpected_wait, "a resume run started to wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| 2.times { second_resume_create_entry(company) } }

      root = live_handoff_report_root
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, report_root: root, sleeper: no_wait,
                                         observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)

      # No catch-up here: until the resume's freeze stores P, the projection
      # refuses these previous-generation snapshots, so the resume's own
      # freeze drain delivers them.
      live_handoff_resume_relay
      Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: root, sleeper: no_wait)
      before_second = second_resume_state(companies)

      # Once flipped, Steps.decide_idle answers readmit, so the second resume only re-sends admit and returns nil.
      expect(Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: root, sleeper: no_wait))
        .to be_nil

      # "A second resume changes nothing": compare projection rows, receipts, outbox positions, the ownership row and money, byte for byte, before and after the second resume.
      after_second = second_resume_state(companies)
      before_second.each_key do |part|
        expect(after_second.fetch(part)).to eq(before_second.fetch(part)), "#{part} changed on the second resume"
      end
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff: abort from during_checkpoint", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def checkpoint_abort_create_entry(company)
    user = User.with_role(:owner, company).order(:id).find { |candidate| candidate.token.present? } ||
           raise("#{company.name} has no seeded owner with an API token")
    project = company.projects.kept.order(:id).first!
    headers = { "X-Auth-Email" => user.email, "X-Auth-Token" => user.token,
                "Idempotency-Key" => "ih-checkpoint-abort-#{SecureRandom.hex(8)}" }
    reply = LiveHandoff.send_request(
      @integrated_runtime.monolith_url,
      { method: "POST", path: "/api/v1/timesheet_entry", headers:,
        body: { "project_id" => project.id,
                "timesheet_entry" => { "duration" => 30.0, "note" => "ih checkpoint abort",
                                       "work_date" => Date.current.iso8601 } } }
    )
    expect(reply.status).to eq(200), "entry create answered #{reply.status}: #{reply.body}"
    JSON.parse(reply.body).fetch("entry").fetch("id")
  end

  def checkpoint_abort_queued(companies)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      companies.flat_map { |company| TimekeepingLiveHandoff.queued_positions(connection, company_id: company.id) }
    end
  end

  # Interrupted at during_checkpoint, handoff_step is "freeze", so the abort
  # owes no step and readmits at once. This example therefore proves only
  # that such an abort returns the prior owner with reconciliation and money
  # intact; the before_freeze abort examples prove the drain-before-readmit
  # ordering.
  it "an abort after a during_checkpoint interrupt returns the prior owner at once, with reconciliation passing and money unchanged on each company" do
    unexpected_wait = Class.new(StandardError)
    no_wait = ->(_seconds) { raise unexpected_wait, "a run that owes no unfinished step started to wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      entry_ids = companies.flat_map { |company| 2.times.map { checkpoint_abort_create_entry(company) } }
      expect(checkpoint_abort_queued(companies).size).to eq(entry_ids.size)
      money_before = companies.to_h { |company| [company.id, TimekeepingLiveHandoff.money(company_id: company.id)] }

      root = live_handoff_report_root
      interrupt = TimekeepingHandoffHooks::Interrupt.new(at: :during_checkpoint)
      at_checkpoint = []
      observer = lambda do |event, step:|
        if event == :during_checkpoint
          at_checkpoint << {
            queued: checkpoint_abort_queued(companies),
            projected: ActiveRecord::Base.uncached { TimesheetEntry.unscoped.where(id: entry_ids).pluck(:id) }
          }
        end
        interrupt.call(event, step:)
      end
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, observer:, report_root: root, sleeper: no_wait)
      end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      live_handoff_resume_relay
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, observer:, report_root: root,
                                         sleeper: no_wait)
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      # The queue state at the interrupt: drained, with every queued entry in the projection.
      expect(at_checkpoint.size).to eq(1)
      expect(at_checkpoint.first.fetch(:queued)).to eq([])
      expect(at_checkpoint.first.fetch(:projected)).to match_array(entry_ids)
      step = TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).handoff_step }
      expect(step).to eq("freeze")

      expect(Timekeeping::Handoff::Runner.run(direction: :rollback, abort: true, report_root: root, sleeper: no_wait))
        .to be_nil

      ownership = TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
      expect([ownership.owner, ownership.handoff_step]).to eq(["timekeeping", nil])
      reconciliation = live_handoff_aborted_reconciliation(root)
      expect(reconciliation.abort?).to be(false), reconciliation.to_h.inspect
      companies.each do |company|
        after = TimekeepingLiveHandoff.money(company_id: company.id)
        expect(Timekeeping::FinancialSnapshot.compare(money_before.fetch(company.id), after)).to eq([]), company.name
      end
    end
  end
end

RSpec.describe "Timekeeping interrupted handoff: redelivery after the flip", :integrated_runtime, :inline_jobs_on_dedicated_queues, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  def redelivery_create_entry(company)
    user = User.with_role(:owner, company).order(:id).find { |candidate| candidate.token.present? } ||
           raise("#{company.name} has no seeded owner with an API token")
    project = company.projects.kept.order(:id).first!
    headers = { "X-Auth-Email" => user.email, "X-Auth-Token" => user.token,
                "Idempotency-Key" => "ih-redelivery-#{SecureRandom.hex(8)}" }
    reply = LiveHandoff.send_request(
      @integrated_runtime.monolith_url,
      { method: "POST", path: "/api/v1/timesheet_entry", headers:,
        body: { "project_id" => project.id,
                "timesheet_entry" => { "duration" => 30.0, "note" => "ih redelivery",
                                       "work_date" => Date.current.iso8601 } } }
    )
    expect(reply.status).to eq(200), "entry create answered #{reply.status}: #{reply.body}"
  end

  # The runtime's relay worker sends from its own process, so its batches
  # cannot be captured here. With both relay locks held, the shared relay
  # code delivers the queued rows through an endpoint that records each
  # batch, its Idempotency-Key and the answer, from a source that reads
  # outbox_snapshots by SQL, as spec/integration/timekeeping/late_replay_spec.rb
  # does.
  def redelivery_capture_batches
    entry_fields = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/entry_snapshots.yml")).fetch("entry_fields")
    deliveries = []
    with_live_relays_held do |timekeeping|
      source = Object.new
      source.define_singleton_method(:unsent_after) do |position, limit|
        timekeeping.exec_params(
          "SELECT generation, outbox_position, row_to_json(o)::text FROM outbox_snapshots o " \
          "WHERE sent_at IS NULL AND outbox_position > $1 ORDER BY outbox_position LIMIT $2", [position, limit]
        ).values.map do |generation, outbox_position, row_json|
          { "generation" => Integer(generation), "outbox_position" => Integer(outbox_position),
            "entry" => JSON.parse(row_json).slice(*entry_fields) }
        end
      end
      source.define_singleton_method(:mark_sent) do |positions|
        timekeeping.exec_params("UPDATE outbox_snapshots SET sent_at = now() WHERE outbox_position = ANY($1::bigint[])",
                                ["{#{positions.map { |position| Integer(position) }.join(',')}}"])
        nil
      end
      endpoint = TimekeepingRelay::HttpEndpoint.new(url: @integrated_runtime.monolith_url,
                                                    token: @integrated_runtime.credentials.service_token)
      recorder = Object.new
      recorder.define_singleton_method(:deliver) do |batch, idempotency_key:|
        endpoint.deliver(batch, idempotency_key:).tap do |answer|
          deliveries << { batch:, key: idempotency_key, status: answer.status }
        end
      end
      TimekeepingRelay::Relay.new(source:, endpoint: recorder).deliver(limit: Timekeeping::RelayJob::BATCH_SIZE)
    end
    deliveries
  end

  def redelivery_send(delivery, key:)
    LiveHandoff.send_request(
      @integrated_runtime.monolith_url,
      { method: "POST", path: TimekeepingRelay::HttpEndpoint::DELIVER_PATH, body: delivery.fetch(:batch),
        headers: { "Authorization" => "Bearer #{@integrated_runtime.credentials.service_token}",
                   "Idempotency-Key" => key, "Content-Type" => "application/json" } }
    )
  end

  def redelivery_projection_rows(entry_ids)
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_rows(
        TimesheetEntry.sanitize_sql_array(["SELECT * FROM timesheet_entries WHERE id IN (?) ORDER BY id", entry_ids])
      )
    end
  end

  def redelivery_receipt_count
    ActiveRecord::Base.uncached { EntrySnapshotReceipt.count }
  end

  it "after a resumed rollback flips, a same-key replay gets its stored 200 and a fresh-key previous-generation batch gets 409 stale_generation, changing no projection row or receipt" do
    unexpected_wait = Class.new(StandardError)
    no_wait = ->(_seconds) { raise unexpected_wait, "a resume started to wait" }
    companies = [fork_and_leaf, copper_kettle]

    with_live_handoff do
      live_handoff_cutover!
      live_handoff_catch_up!
      live_handoff_pause_relay
      companies.each { |company| redelivery_create_entry(company) }
      deliveries = redelivery_capture_batches
      expect(deliveries).not_to be_empty
      expect(deliveries.map { |delivery| delivery.fetch(:status) }).to all(eq(200))
      accepted = deliveries.first
      batch = JSON.parse(accepted.fetch(:batch))
      entry_ids = batch.fetch("snapshots").map { |snapshot| snapshot.fetch("entry").fetch("id") }.uniq
      receipt = ActiveRecord::Base.uncached do
        EntrySnapshotReceipt.find_by!(company_ids: batch.fetch("snapshots").map { |snapshot| snapshot.dig("entry", "company_id") }.uniq.sort,
                                      actor: "timekeeping", key: accepted.fetch(:key))
      end

      companies.each { |company| redelivery_create_entry(company) }
      root = live_handoff_report_root
      expect do
        Timekeeping::Handoff::Runner.run(direction: :rollback, report_root: root, sleeper: no_wait,
                                         observer: TimekeepingHandoffHooks::Interrupt.new(at: :before_freeze))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      live_handoff_resume_relay
      expect(Timekeeping::Handoff::Runner.run(direction: :rollback, resume: true, report_root: root, sleeper: no_wait))
        .to be_nil
      ownership = TimekeepingOwnership.uncached { TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID) }
      expect(ownership.owner).to eq("monolith")
      expect(batch.fetch("snapshots").map { |snapshot| snapshot.fetch("generation") }).to all(eq(ownership.generation - 1))

      rows_before = redelivery_projection_rows(entry_ids)
      receipts_before = redelivery_receipt_count

      # SnapshotDeliveryReceipts#stored_answer runs before the generation check,
      # so the same key is answered from the receipt.
      replay = redelivery_send(accepted, key: accepted.fetch(:key))
      expect([replay.status, replay.body]).to eq([receipt.response_status, receipt.response_body.to_json.b])

      # A fresh key has no receipt, so the batch reaches the generation check.
      stale = redelivery_send(accepted, key: "ih-redelivery-stale-#{SecureRandom.hex(8)}")
      expect(stale.status).to eq(409)
      expect(JSON.parse(stale.body)).to eq("reason" => "stale_generation")

      expect(redelivery_projection_rows(entry_ids)).to eq(rows_before)
      expect(redelivery_receipt_count).to eq(receipts_before)
    end
  end
end

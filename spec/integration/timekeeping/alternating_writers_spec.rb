# frozen_string_literal: true

require "rails_helper"
require "json"
require "securerandom"

# Alternates web and CLI edits of one entry per seeded company across a real
# cutover, rollback and re-cutover against the local runtime, and proves the
# last accepted values win in Timekeeping and the projection, every accepted
# edit is audited exactly once in the store that owns the entry, edits sent
# while admission is closed are refused without an audit row, and no row,
# audit entry or outbox message of one company names the other.
#
# Every handoff shares one example, because the runtime hooks empty the
# monolith after every example. The :integrated_runtime tag skips it unless
# the live flag is set (spec/support/timekeeping/integrated_runtime.rb), and
# runs it under the queue ledger and the runtime's own database resets.
RSpec.describe "Timekeeping alternating writers", :integrated_runtime, :two_tenant_seed, committed_data: true,
                                                  owner_state: "legacy" do
  # handoff_sequence_spec.rb writes on the same date, inside the seed's edit window.
  let(:alternating_work_date) { "2026-01-07" }

  it "keeps the last accepted duration and note, audits each accepted edit once and never crosses tenants across cutover, rollback and re-cutover" do
    company_ids = [fork_and_leaf.id, copper_kettle.id]
    @alternating_run_token = SecureRandom.hex(4)
    @alternating_writers = [fork_and_leaf, copper_kettle].to_h { |company| [company.id, alternating_writer(company)] }
    @alternating_accepted = company_ids.index_with { [] }
    url = ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY)
    TestDatabaseGuard.require_test_database_url!(url)
    @alternating_timekeeping = TimekeepingDatabaseReset.connect(url, TimekeepingDatabaseReset.database_name(url))
    baselines = company_ids.index_with { |id| Timekeeping::FinancialSnapshot.take(company_id: id) }

    with_live_handoff_integrations(@integrated_runtime) do
      # Every seeded Copper Kettle Bakery entry is billed, so each owner
      # creates an entry of their own to edit.
      @alternating_writers.each_value { |writer| create_alternating_entry(writer) }
      accept_alternating_edits(2)
      expect_alternating_stage("after setup edits", store: :legacy, outbox_required: false)

      pause = { fired: false, replies: [], tenant_failures: [], error: nil }
      run_alternating_handoff(:cutover, company_ids:, baselines:, observer: paused_edit_observer(pause))

      # The observer only records, so the runner is never stopped mid-step;
      # its findings are judged here, after the cutover's own checks passed.
      expect(pause[:error]).to be_nil
      expect(pause[:fired]).to be(true), "the close_admission hook never fired during cutover"
      expect(pause[:replies].size).to eq(2 * company_ids.size)
      pause[:replies].each do |paused|
        edit = paused.fetch(:edit)
        reply = paused.fetch(:reply)
        label = "company #{edit[:company_id]} #{edit[:via]} edit #{edit[:sequence]} during the pause"
        expect(reply.status).to eq(503), "#{label} answered #{reply.status}"
        expect(alternating_reason(reply)).to eq("ownership_moving"), label
        expect(paused.fetch(:audit_counts)).to eq(legacy: 0, prepared: 0, timekeeping: 0), label
      end
      expect(pause[:tenant_failures]).to eq([])

      # "Check zero audit rows for it before the retry, then exactly one after a successful retry."
      pause[:replies].each do |paused|
        edit = paused.fetch(:edit)
        expect(alternating_audit_counts(edit)).to eq(legacy: 0, prepared: 0, timekeeping: 0),
                                                  "company #{edit[:company_id]} edit #{edit[:sequence]} before its retry"
        accept_alternating_edit(edit)
      end
      expect_alternating_stage("after the paused edits were retried", store: :timekeeping, outbox_required: true)

      accept_alternating_edits(2)
      expect_alternating_stage("after edits following cutover", store: :timekeeping, outbox_required: true)

      run_alternating_handoff(:rollback, company_ids:, baselines:)
      expect_alternating_stage("after rollback", store: :prepared, outbox_required: false)
      accept_alternating_edits(2)
      expect_alternating_stage("after edits following rollback", store: :prepared, outbox_required: true)

      run_alternating_handoff(:re_cutover, company_ids:, baselines:)
      expect_alternating_stage("after re-cutover", store: :timekeeping, outbox_required: false)
      accept_alternating_edits(2)
      expect_alternating_stage("after edits following re-cutover", store: :timekeeping, outbox_required: true)

      @alternating_writers.each_value { |writer| wait_for_alternating_final_values(writer) }
    end
  ensure
    @alternating_timekeeping&.close
  end

  # run_live_handoff checks the new owner, the risen generation, a nil
  # handoff_step and a clean reconciliation report, whose money comparison
  # covers every company; the snapshots repeat that check here per company.
  def run_alternating_handoff(direction, company_ids:, baselines:, observer: Timekeeping::Handoff::NullObserver.new)
    run_live_handoff(direction, company_ids:, observer:)
    company_ids.each do |id|
      later = Timekeeping::FinancialSnapshot.take(company_id: id)
      expect(Timekeeping::FinancialSnapshot.compare(baselines.fetch(id), later)).to eq([]), "#{direction}, company #{id}"
    end
  end

  # Sends one web and one CLI edit per company once admission is closed, and
  # records the replies, their audit counts in every store and the tenant
  # check. It never raises: the runner does not rescue its observer, so a
  # raise would leave the handoff fenced and skip the checks after the run.
  def paused_edit_observer(pause)
    lambda do |event, step:|
      next unless event == :after_step && step == "close_admission"

      pause[:fired] = true
      @alternating_writers.each_value do |writer|
        %i[web cli].each do |via|
          edit = next_alternating_edit(writer, via:)
          reply = send_alternating_edit(edit)
          pause[:replies] << { edit:, reply:, audit_counts: alternating_audit_counts(edit) }
        end
      end
      pause[:tenant_failures] = alternating_tenant_failures("during the pause", outbox_required: false)
    rescue StandardError => e
      pause[:error] = "#{e.class}: #{e.message}"
    end
  end

  def alternating_writer(company)
    owner = User.with_role(:owner, company).first
    { company_id: company.id, owner:, project: company.projects.kept.first, entry_id: nil, sequence: 0,
      next_via: :web }
  end

  # Notes carry the company id and the run's token, so every note is unique
  # across both companies and one company's notes can be searched for under
  # the other's id. The trailing space keeps company 1 from matching company 12.
  def alternating_note_prefix(company_id)
    "alternating writers #{@alternating_run_token} company #{company_id} "
  end

  def create_alternating_entry(writer)
    reply = LiveHandoff.send_request(@integrated_runtime.monolith_url, {
      method: "POST", path: "/api/v1/timesheet_entry", headers: alternating_credentials(writer),
      body: { "project_id" => writer[:project].id,
              "timesheet_entry" => { "duration" => 30.0, "note" => "#{alternating_note_prefix(writer[:company_id])}create",
                                     "work_date" => alternating_work_date } }
    })
    expect(reply.status).to eq(200), "company #{writer[:company_id]} could not create its entry"
    writer[:entry_id] = JSON.parse(reply.body).fetch("entry").fetch("id")
  end

  # Every edit changes both note and duration to values no earlier edit of
  # the entry used: a converted audit holds only the fields that changed.
  def next_alternating_edit(writer, via:)
    writer[:sequence] += 1
    sequence = writer[:sequence]
    { company_id: writer[:company_id], entry_id: writer[:entry_id], via:, sequence:,
      note: "#{alternating_note_prefix(writer[:company_id])}edit #{sequence}", duration: 30.0 + sequence }
  end

  # Sends count edits per company, alternating web and CLI, and requires each
  # to be accepted.
  def accept_alternating_edits(count)
    @alternating_writers.each_value do |writer|
      count.times do
        via = writer[:next_via]
        writer[:next_via] = via == :web ? :cli : :web
        accept_alternating_edit(next_alternating_edit(writer, via:))
      end
    end
  end

  # Only an edit the server accepted joins the expected history.
  def accept_alternating_edit(edit)
    reply = send_alternating_edit(edit)
    expect(reply.status).to eq(200),
                            "company #{edit[:company_id]} #{edit[:via]} edit #{edit[:sequence]} answered #{reply.status}"
    @alternating_accepted.fetch(edit[:company_id]) << edit
  end

  # No Idempotency-Key is sent, so a retry is a new write and can never be
  # answered from a stored refusal.
  def send_alternating_edit(edit)
    writer = @alternating_writers.fetch(edit[:company_id])
    request = alternating_edit_request(edit, project_id: writer[:project].id)
    LiveHandoff.send_request(@integrated_runtime.monolith_url, request.merge(headers: alternating_credentials(writer)))
  end

  # The web route takes the project at the top level and the duration as
  # duration; the CLI route takes both inside timesheet_entry, the duration
  # as duration_minutes.
  def alternating_edit_request(edit, project_id:)
    if edit[:via] == :cli
      { method: "PATCH", path: "/api/v1/cli/timesheet_entries/#{edit[:entry_id]}",
        body: { "timesheet_entry" => { "project_id" => project_id, "duration_minutes" => edit[:duration],
                                       "work_date" => alternating_work_date, "note" => edit[:note] } } }
    else
      { method: "PATCH", path: "/api/v1/timesheet_entry/#{edit[:entry_id]}",
        body: { "project_id" => project_id,
                "timesheet_entry" => { "duration" => edit[:duration], "work_date" => alternating_work_date,
                                       "note" => edit[:note] } } }
    end
  end

  def alternating_credentials(writer)
    { "X-Auth-Email" => writer[:owner].email, "X-Auth-Token" => writer[:owner].token }
  end

  def alternating_reason(reply)
    parsed = JSON.parse(reply.body)
    parsed.is_a?(Hash) ? parsed["reason"] : nil
  rescue JSON::ParserError
    nil
  end

  def expect_alternating_stage(stage, store:, outbox_required:)
    expect(alternating_audit_failures(stage, store:)).to eq([])
    expect(alternating_tenant_failures(stage, outbox_required:)).to eq([])
  end

  # Every accepted edit so far must have exactly one audit row in the store
  # that owns the entries now.
  def alternating_audit_failures(stage, store:)
    @alternating_accepted.values.flatten.filter_map do |edit|
      count = alternating_audit_count(store, edit)
      next if count == 1

      "#{stage}: company #{edit[:company_id]} entry #{edit[:entry_id]} edit #{edit[:sequence]} " \
        "has #{count} audit rows in the #{store} store"
    end
  end

  def alternating_audit_counts(edit)
    %i[legacy prepared timekeeping].index_with { |store| alternating_audit_count(store, edit) }
  end

  # Each count is bound to the edit's company, entry and new note.
  def alternating_audit_count(store, edit)
    binds = [edit[:company_id], edit[:entry_id], edit[:note]]
    case store
    when :legacy then legacy_alternating_audit_count(edit)
    when :prepared
      ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM entry_audits WHERE company_id = $1 AND entry_id = $2 AND after->>'note' = $3",
          "alternating writers", binds
        ).to_i
      end
    when :timekeeping
      @alternating_timekeeping.exec_params(
        "SELECT count(*) FROM audit_events WHERE company_id = $1 AND entry_id = $2 AND after->>'note' = $3", binds
      ).getvalue(0, 0).to_i
    end
  end

  # audited_changes is serialized text holding [old, new] for an update, so
  # a text match would also find the next edit's row, where this note is the
  # old value. Only the deserialized new value counts.
  def legacy_alternating_audit_count(edit)
    ActiveRecord::Base.uncached do
      Audited::Audit.where(auditable_type: "TimesheetEntry", auditable_id: edit[:entry_id],
                           associated_type: "Company", associated_id: edit[:company_id]).to_a.count do |audit|
        note = audit.audited_changes["note"]
        note.is_a?(Array) && note.last == edit[:note]
      end
    end
  end

  # Rows, audit entries and outbox messages tied to each company's own entry
  # or notes, read from both stores. Each row must name its own company only,
  # and rows and audit entries must exist, so an empty query cannot pass.
  # Outbox messages are required only once the current owner has written for
  # the entry: the legacy store keeps no outbox, and a handoff alone writes
  # none. entry_snapshot_receipts is left out because one receipt names every
  # company of a relay batch.
  def alternating_tenant_failures(stage, outbox_required:)
    surfaces = { rows: {}, audit_entries: {}, outbox_messages: {} }
    @alternating_writers.each_value do |writer|
      company_id = writer[:company_id]
      binds = [writer[:entry_id], "%#{alternating_note_prefix(company_id)}%"]
      surfaces[:rows][company_id] = alternating_tenant_rows(alternating_row_queries, binds)
      surfaces[:audit_entries][company_id] = alternating_tenant_rows(alternating_audit_queries, binds)
      surfaces[:outbox_messages][company_id] = alternating_tenant_rows(alternating_outbox_queries, binds)
    end

    company_ids = @alternating_writers.keys
    surfaces.flat_map do |surface, rows_by_company|
      own_rows_required = surface != :outbox_messages || outbox_required
      checked_ids = own_rows_required ? company_ids : company_ids.select { |id| rows_by_company.fetch(id).any? }
      LiveHandoff.foreign_id_failures(rows_by_company, company_ids: checked_ids)
                 .map { |failure| "#{stage}: #{surface}: #{failure}" }
    end
  end

  # Each query takes the entry id as $1 and the company's note pattern as $2
  # and returns the company each matching row names.
  def alternating_row_queries
    {
      monolith: [
        "SELECT company_id FROM timesheet_entries WHERE id = $1 OR note LIKE $2",
        "SELECT company_id FROM entries WHERE id = $1 OR note LIKE $2"
      ],
      timekeeping: ["SELECT company_id FROM entries WHERE id = $1 OR note LIKE $2"]
    }
  end

  # audits has no company column: TimesheetEntry is audited with its company
  # as the associated record, so any other association names no company.
  def alternating_audit_queries
    {
      monolith: [
        "SELECT CASE WHEN associated_type = 'Company' THEN associated_id END AS company_id FROM audits " \
        "WHERE auditable_type = 'TimesheetEntry' AND (auditable_id = $1 OR audited_changes LIKE $2)",
        "SELECT company_id FROM entry_audits WHERE entry_id = $1 OR after->>'note' LIKE $2 OR before->>'note' LIKE $2"
      ],
      timekeeping: [
        "SELECT company_id FROM audit_events WHERE entry_id = $1 OR after->>'note' LIKE $2 OR before->>'note' LIKE $2"
      ]
    }
  end

  # An outbox payload that names a company is checked as well as its row.
  def alternating_outbox_queries
    {
      monolith: [
        "SELECT company_id FROM entry_outbox_items WHERE entry_id = $1 OR payload->>'note' LIKE $2",
        "SELECT (payload->>'company_id')::bigint AS company_id FROM entry_outbox_items " \
        "WHERE (entry_id = $1 OR payload->>'note' LIKE $2) AND payload->>'company_id' IS NOT NULL"
      ],
      timekeeping: ["SELECT company_id FROM outbox_snapshots WHERE id = $1 OR note LIKE $2"]
    }
  end

  def alternating_tenant_rows(queries, binds)
    monolith = ActiveRecord::Base.uncached do
      queries.fetch(:monolith).flat_map do |sql|
        ActiveRecord::Base.connection.select_values(sql, "alternating writers", binds)
      end
    end
    timekeeping = queries.fetch(:timekeeping).flat_map do |sql|
      @alternating_timekeeping.exec_params(sql, binds).column_values(0)
    end
    (monolith + timekeeping).map { |company_id| { "company_id" => company_id&.to_i } }
  end

  # The projection is filled by the runtime's relay on its own schedule, so
  # both stores are read until they hold the last accepted values.
  def wait_for_alternating_final_values(writer)
    company_id = writer[:company_id]
    entry_id = writer[:entry_id]
    last = @alternating_accepted.fetch(company_id).last
    expected = { "duration" => last[:duration], "note" => last[:note] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      observed = {
        timekeeping: alternating_values(@alternating_timekeeping.exec_params(
          "SELECT duration, note FROM entries WHERE id = $1 AND company_id = $2", [entry_id, company_id]
        ).first),
        projection: alternating_values(ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_one(
            "SELECT duration, note FROM timesheet_entries WHERE id = $1 AND company_id = $2",
            "alternating writers", [entry_id, company_id]
          )
        end)
      }
      return if observed.values.all?(expected)

      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if waited > 60
        raise "company #{company_id} entry #{entry_id} did not reach #{expected} in Timekeeping and the projection " \
              "within 60 s; saw #{observed}"
      end

      sleep 1
    end
  end

  def alternating_values(row)
    return nil unless row

    { "duration" => Float(row.fetch("duration")), "note" => row.fetch("note") }
  end
end

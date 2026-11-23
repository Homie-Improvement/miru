# frozen_string_literal: true

require "rails_helper"
require "json"
require "net/http"
require "securerandom"

# A rollback from Timekeeping interrupted while entry snapshots are still
# queued behind a paused relay, then resumed or aborted, run against the live
# demo runtime on both seeded companies (docs/architecture/timekeeping-soa.md
# sections 10.4 and 10.5). The :integrated_runtime tag skips it unless the live
# flag is set (spec/support/timekeeping/integrated_runtime.rb), so the default
# suite skips it, and the CI live job does not run it.
#
# A first cutover from legacy stores the final outbox position P = 0, so
# snapshots can queue only while Timekeeping is the outgoing owner. Each
# example therefore cuts over for real, delivers what the cutover left, pauses
# the relay, edits entries so snapshots queue, and only then starts the
# rollback under a second report root.
#
# Freeze stores P and then drains every snapshot through P before checkpoint,
# so a run with the relay paused is refused at freeze, and checkpoint is
# reached only after the relay resumes. Every queued snapshot is at or below P,
# because nothing is written after the rollback starts.
#
# Every Runner.run call passes a sleeper. An abort waits for an unfinished
# freeze with no timeout, so a call that fell back to Kernel#sleep would hang
# the suite while holding the handoff lock; the sleepers here fail instead.
RSpec.describe "Timekeeping interrupted handoff", :integrated_runtime, :two_tenant_seed,
               committed_data: true, owner_state: "legacy" do
  include_context "timekeeping live handoff"

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  # More polls than the paused abort needs: it resumes the relay on poll 2.
  def interrupted_handoff_poll_cap = 10

  def interrupted_handoff_companies = [fork_and_leaf, copper_kettle]

  # An owner or admin of the company who can sign requests with the legacy
  # X-Auth-Email and X-Auth-Token headers.
  def interrupted_handoff_admin(company)
    company.users.order(:id).find do |user|
      user.token.present? && user.current_workspace_id == company.id && user.employed_at?(company.id) &&
        (user.has_role?(:owner, company) || user.has_role?(:admin, company))
    end || raise("#{company.name} has no seeded owner or admin with an API token")
  end

  def interrupted_handoff_project(company)
    Project.kept.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first ||
      raise("#{company.name} has no seeded billable project")
  end

  def interrupted_handoff_request(method, path, user:, body: nil)
    uri = URI.join(@integrated_runtime.monolith_url, path)
    request = { post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method).new(uri)
    request["X-Auth-Email"] = user.email
    request["X-Auth-Token"] = user.token
    request["Accept"] = "application/json"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  # Creates an entry through the monolith, which forwards it to Timekeeping
  # while Timekeeping owns entries, and returns its id.
  def interrupted_handoff_create_entry(company)
    response = interrupted_handoff_request(
      :post, "/api/v1/timesheet_entry", user: interrupted_handoff_admin(company),
      body: {
        project_id: interrupted_handoff_project(company).id,
        timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Interrupted handoff", bill_status: "unbilled" }
      }
    )
    expect(response.code).to eq("200"), "entry create answered #{response.code}: #{response.body}"
    Integer(JSON.parse(response.body).dig("entry", "id"))
  end

  # Each update writes one outbox snapshot in Timekeeping.
  def interrupted_handoff_update_entry(company, entry_id, note:)
    response = interrupted_handoff_request(
      :patch, "/api/v1/timesheet_entry/#{Integer(entry_id)}", user: interrupted_handoff_admin(company),
      body: { project_id: interrupted_handoff_project(company).id, timesheet_entry: { note: } }
    )
    expect(response.code).to eq("200"), "entry update answered #{response.code}: #{response.body}"
  end

  # Changes only an invoice's reference, so an admitted save sends no
  # reservation operation. Returns [status, reason] without raising, because
  # it also runs inside the runner's observer and sleeper.
  def interrupted_handoff_billing_write(company)
    invoice = ActiveRecord::Base.uncached { company.invoices.kept.order(:id).first! }
    response = interrupted_handoff_request(
      :patch, "/api/v1/invoices/#{invoice.id}", user: interrupted_handoff_admin(company),
      body: { invoice: { client_id: invoice.client_id, reference: "HELD" } }
    )
    reason = response.body.to_s.start_with?("{") ? JSON.parse(response.body)["reason"] : response.body
    [response.code, reason]
  end

  def interrupted_handoff_billing_writes
    interrupted_handoff_companies.to_h { |company| [company.name, interrupted_handoff_billing_write(company)] }
  end

  def interrupted_handoff_billing_refused
    interrupted_handoff_companies.to_h { |company| [company.name, ["503", "ownership_moving"]] }
  end

  # Posts a snapshot batch to the monolith's projection endpoint as the
  # Timekeeping service does.
  def interrupted_handoff_deliver(body, key:)
    uri = URI.join(@integrated_runtime.monolith_url, "/internal/v1/timekeeping/entry-snapshots")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@integrated_runtime.credentials.service_token}"
    request["Content-Type"] = "application/json"
    request["Idempotency-Key"] = key
    request.body = body
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  def interrupted_handoff_ownership
    TimekeepingOwnership.uncached do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)
                          .pick(:owner, :generation, :handoff_step, :final_outbox_position)
    end.then do |owner, generation, handoff_step, final_outbox_position|
      { owner:, generation:, handoff_step:, final_outbox_position: }
    end
  end

  def interrupted_handoff_money
    interrupted_handoff_companies.to_h { |company| [company.id, TimekeepingLiveHandoff.money(company_id: company.id)] }
  end

  def interrupted_handoff_queued_positions
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      interrupted_handoff_companies.flat_map do |company|
        TimekeepingLiveHandoff.queued_positions(connection, company_id: company.id)
      end.sort
    end
  end

  def interrupted_handoff_admission_text
    TimekeepingLiveHandoff.with_timekeeping_database { |connection| TimekeepingLiveHandoff.admission_text(connection) }
  end

  def interrupted_handoff_sent_positions(positions)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      connection.exec_params(
        "SELECT outbox_position FROM outbox_snapshots WHERE sent_at IS NOT NULL " \
        "AND outbox_position = ANY($1::bigint[]) ORDER BY outbox_position",
        [PG::TextEncoder::Array.new.encode(positions)]
      ).column_values(0).map { |position| Integer(position) }
    end
  end

  # { entry id => [version, note] } of the newest outbox snapshot of every
  # entry that has a snapshot at one of the positions: the outgoing owner's
  # latest version of each queued entry.
  def interrupted_handoff_latest_outgoing(positions)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      connection.exec_params(<<~SQL.squish, [PG::TextEncoder::Array.new.encode(positions)]).values
        SELECT DISTINCT ON (id) id, version, note FROM outbox_snapshots
        WHERE id IN (SELECT id FROM outbox_snapshots WHERE outbox_position = ANY($1::bigint[]))
        ORDER BY id, outbox_position DESC
      SQL
    end.to_h { |id, version, note| [Integer(id), [Integer(version), note]] }
  end

  # { entry id => [version, note] } of the monolith projection, uncached
  # because the relay writes it through the runtime's own connections.
  def interrupted_handoff_projection(entry_ids)
    ids = entry_ids.map { |id| Integer(id) }
    return {} if ids.empty?

    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_rows(
        "SELECT id, version, note FROM timesheet_entries WHERE id IN (#{ids.join(', ')})"
      )
    end.to_h { |id, version, note| [Integer(id), [Integer(version), note]] }
  end

  # The projection keeps one row per entry id, so two queued versions of one
  # entry leave one row. Every queued snapshot reached the projection when no
  # snapshot through P is unsent, every queued position is marked sent, and
  # each queued entry's projection row is its latest outgoing version.
  def interrupted_handoff_delivery(queued, through:)
    latest = interrupted_handoff_latest_outgoing(queued)
    {
      unsent: TimekeepingLiveHandoff.with_timekeeping_database do |connection|
        TimekeepingLiveHandoff.unsent_outbox_positions(connection, through:)
      end,
      sent: interrupted_handoff_sent_positions(queued),
      latest:,
      projection: interrupted_handoff_projection(latest.keys)
    }
  end

  def interrupted_handoff_expect_delivered(delivery, queued)
    expect(delivery.fetch(:unsent)).to eq([])
    expect(delivery.fetch(:sent)).to eq(queued)
    expect(delivery.fetch(:latest)).not_to be_empty
    expect(delivery.fetch(:projection)).to eq(delivery.fetch(:latest))
  end

  # Everything "a second resume changes nothing" compares.
  def interrupted_handoff_state
    company_ids = interrupted_handoff_companies.map(&:id)
    TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      TimekeepingLiveHandoff.state_snapshot(connection, company_ids:)
    end.merge(digests: company_ids.to_h { |company_id| [company_id, TimekeepingLiveHandoff.tenant_digest(company_id:)] })
  end

  # Passes the observed event to record, then to the interrupt, if any.
  def interrupted_handoff_observer(interrupt_at: nil, &record)
    interrupt = interrupt_at && TimekeepingHandoffHooks::Interrupt.new(at: interrupt_at)
    lambda do |event, step:|
      record.call(event, step.to_s)
      interrupt&.call(event, step:)
    end
  end

  # For a run that must finish or refuse without waiting.
  def interrupted_handoff_no_sleep
    ->(_seconds) { raise "this handoff run tried to wait; it must finish or refuse without sleeping" }
  end

  # Records each poll's interval, runs on_poll with the poll number, and
  # fails past the cap instead of waiting for ever.
  def interrupted_handoff_counting_sleeper(polls, &on_poll)
    lambda do |seconds|
      polls << seconds
      raise "the abort was still waiting after #{interrupted_handoff_poll_cap} polls" if polls.size > interrupted_handoff_poll_cap

      on_poll.call(polls.size)
    end
  end

  def interrupted_handoff_run(report_root:, observer: Timekeeping::Handoff::NullObserver.new,
                              sleeper: interrupted_handoff_no_sleep, **options)
    Timekeeping::Handoff::Runner.run(direction: :rollback, report_root:, observer:, sleeper:, **options)
  end

  # Cuts over from legacy, creates two entries per company and delivers them,
  # pauses the relay, then edits one entry twice and the other once. Each
  # company then has three queued snapshots: two versions of one entry and a
  # single edit of another. Returns every queued position, in order.
  def interrupted_handoff_queue_snapshots!
    live_handoff_cutover!
    entries = interrupted_handoff_companies.to_h do |company|
      [company, Array.new(2) { interrupted_handoff_create_entry(company) }]
    end
    live_handoff_catch_up!
    live_handoff_pause_relay

    entries.each do |company, (edited_twice, edited_once)|
      interrupted_handoff_update_entry(company, edited_twice, note: "Interrupted handoff v2")
      interrupted_handoff_update_entry(company, edited_twice, note: "Interrupted handoff v3")
      interrupted_handoff_update_entry(company, edited_once, note: "Interrupted handoff edited")
      TimekeepingLiveHandoff.with_timekeeping_database do |connection|
        expect(TimekeepingLiveHandoff.queued_count(connection, company_id: company.id, entry_id: edited_twice)).to eq(2)
        expect(TimekeepingLiveHandoff.queued_count(connection, company_id: company.id, entry_id: edited_once)).to eq(1)
        expect(TimekeepingLiveHandoff.queued_count(connection, company_id: company.id)).to eq(3)
      end
    end

    interrupted_handoff_queued_positions.tap { |queued| expect(queued.size).to eq(6) }
  end

  # Starts the rollback and interrupts it before freeze, after settle stored
  # the money baseline. The queue is read inside the observer and asserted
  # after the run raised.
  def interrupted_handoff_interrupt_before_freeze!(report_root, queued)
    recorded = {}
    observer = interrupted_handoff_observer(interrupt_at: :before_freeze) do |event, step|
      recorded[:queued] = interrupted_handoff_queued_positions if event == :before_step && step == "freeze"
    end

    expect { interrupted_handoff_run(report_root:, observer:) }.to raise_error(TimekeepingHandoffHooks::Interrupted)

    expect(recorded.fetch(:queued).size).to be > 0
    expect(recorded.fetch(:queued)).to eq(queued)
    expect(interrupted_handoff_ownership).to include(owner: "timekeeping", handoff_step: "settle", final_outbox_position: nil)
  end

  # A run with the relay paused stores P, then is refused because freeze
  # cannot drain: the design's point after step 3. Returns P.
  def interrupted_handoff_refused_at_freeze!(report_root, queued)
    expect { interrupted_handoff_run(report_root:) }
      .to raise_error(Timekeeping::Handoff::Runner::Refused, /freeze step did not finish/)

    ownership = interrupted_handoff_ownership
    expect(ownership).to include(owner: "timekeeping", handoff_step: "settle")
    final_outbox_position = ownership.fetch(:final_outbox_position)
    expect(final_outbox_position).to be >= queued.max
    unsent = TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      TimekeepingLiveHandoff.unsent_outbox_positions(connection, through: final_outbox_position)
    end
    expect(unsent).to include(*queued)
    final_outbox_position
  end

  # Interrupts a resumed rollback at checkpoint. Checkpoint is reached only
  # after freeze drained every snapshot through P, so the queue is empty there.
  def interrupted_handoff_interrupt_during_checkpoint!(report_root, queued, through:)
    recorded = {}
    observer = interrupted_handoff_observer(interrupt_at: :during_checkpoint) do |event, _step|
      recorded[:delivery] = interrupted_handoff_delivery(queued, through:) if event == :during_checkpoint
    end

    expect { interrupted_handoff_run(report_root:, observer:) }.to raise_error(TimekeepingHandoffHooks::Interrupted)

    interrupted_handoff_expect_delivered(recorded.fetch(:delivery), queued)
    expect(interrupted_handoff_ownership).to include(owner: "timekeeping", handoff_step: "freeze")
  end

  # One receipt covers every company in its batch, so each receipt written
  # after the baseline is summed once against both companies' queued count.
  def interrupted_handoff_expect_applied_once(baseline, queued)
    expect(TimekeepingLiveHandoff.snapshot_receipts_after(baseline)).not_to be_empty
    expect(TimekeepingLiveHandoff.applied_after(baseline)).to eq(queued.size)
  end

  # Final rows compared with the outgoing store, separately from the receipt
  # count: rows alone cannot show a double apply or a skip.
  def interrupted_handoff_expect_rows_match_outgoing(queued)
    latest = interrupted_handoff_latest_outgoing(queued)
    expect(latest).not_to be_empty
    expect(interrupted_handoff_projection(latest.keys)).to eq(latest)
  end

  def interrupted_handoff_expect_money_unchanged(money_before)
    interrupted_handoff_companies.each do |company|
      expect(TimekeepingLiveHandoff.money(company_id: company.id)).to eq(money_before.fetch(company.id)), company.name
    end
  end

  def interrupted_handoff_expect_resumed!(report_root:, queued:, baseline:, money_before:)
    ownership = interrupted_handoff_ownership
    expect(ownership).to include(owner: "monolith", handoff_step: nil)
    interrupted_handoff_expect_applied_once(baseline, queued)
    interrupted_handoff_expect_rows_match_outgoing(queued)

    reconciliation = JSON.parse(File.read(report_root.join("generation-#{ownership.fetch(:generation)}", "reconciliation.json")))
    expect(reconciliation.fetch("abort")).to be(false)
    interrupted_handoff_companies.each do |company|
      report = reconciliation.fetch("companies").fetch(company.id.to_s)
      expect(report.fetch("abort")).to be(false), company.name
      expect(report.dig("checks", "money")).to eq([]), company.name
    end
    interrupted_handoff_expect_money_unchanged(money_before)
  end

  def interrupted_handoff_expect_second_resume_changes_nothing!(report_root)
    before = interrupted_handoff_state
    interrupted_handoff_run(report_root:)
    expect(interrupted_handoff_state).to eq(before)
  end

  # Rebuilds the batch the relay posted for the queued snapshots, proves it is
  # the one a stored receipt answered by matching its key, then sends it again
  # under that key and under a fresh one.
  def interrupted_handoff_expect_redelivery_answers!(queued, baseline)
    receipts = TimekeepingLiveHandoff.snapshot_receipts_after(baseline)
    rows = TimekeepingLiveHandoff.with_timekeeping_database do |connection|
      TimekeepingLiveHandoff.outbox_relay_rows(connection, positions: queued)
    end
    batch = TimekeepingLiveHandoff.relay_batches(rows).find do |candidate|
      receipts.any? { |receipt| receipt.key == candidate.idempotency_key }
    end
    expect(batch).not_to be_nil, "no rebuilt batch has the key of a receipt written after #{baseline}"
    receipt = receipts.find { |stored| stored.key == batch.idempotency_key }

    unchanged = lambda do
      [interrupted_handoff_companies.map { |company| TimekeepingLiveHandoff.projection_rows_text(company_id: company.id) },
       TimekeepingLiveHandoff.snapshot_receipts_text.size]
    end
    before = unchanged.call

    # The receipt check runs before the generation check, so the same key
    # gets its stored answer after the flip.
    replay = interrupted_handoff_deliver(batch.body, key: batch.idempotency_key)
    expect(replay.code).to eq("200"), replay.body
    expect(JSON.parse(replay.body).fetch("applied")).to eq(receipt.applied)
    expect(unchanged.call).to eq(before)

    # A fresh key reaches the generation check, which refuses the previous
    # generation once the flip ended the handoff.
    refused = interrupted_handoff_deliver(batch.body, key: SecureRandom.uuid)
    expect(refused.code).to eq("409"), refused.body
    expect(JSON.parse(refused.body)).to eq("reason" => "stale_generation")
    expect(unchanged.call).to eq(before)
  end

  # An abort finishes only settle and freeze, so it writes no reconciliation
  # report. This runs the same checks against the owner the abort kept: its
  # state, the projection and the intents now, and money now against the
  # baseline settle stored.
  def interrupted_handoff_expect_abort_reconciles!(report_root)
    store = Timekeeping::Handoff::TimekeepingStore.new
    outgoing = store.export_checkpoint
    highest_entry_id = outgoing.rows.fetch("entries").pluck("id").max || 0
    intents = ActiveRecord::Base.uncached do
      Timekeeping::Handoff::RowReader.select_rows(InvoiceOperationsRecord.connection, Timekeeping::Handoff::Runner::INTENTS_SQL)
    end
    projection = ActiveRecord::Base.uncached do
      Timekeeping::Handoff::RowReader.select_rows(ActiveRecord::Base.connection, Timekeeping::Handoff::Runner::PROJECTION_SQL)
    end
    generation = interrupted_handoff_ownership.fetch(:generation)

    result = Timekeeping::Handoff::Reconciliation.run(
      source: outgoing, checkpoint: outgoing, projection:, source_intents: intents, intents:,
      next_entry_id: store.advance_entry_id_sequence(above: highest_entry_id),
      money_before: Timekeeping::Handoff::ReportDirectory.new(root: report_root, generation:).read_money_before,
      money_after: Company.order(:id).pluck(:id).index_with { |company_id| TimekeepingLiveHandoff.money(company_id:) }
    )

    expect(result.abort?).to be(false), JSON.generate(result.to_h)
    interrupted_handoff_companies.each do |company|
      company_report = result.companies.fetch(company.id)
      expect(company_report.unlisted).to eq([]), company.name
      expect(company_report.checks.fetch(:money)).to eq([]), company.name
    end
  end

  def interrupted_handoff_expect_aborted!(report_root:, queued:, baseline:, money_before:)
    expect(interrupted_handoff_ownership).to include(owner: "timekeeping", handoff_step: nil)
    interrupted_handoff_expect_applied_once(baseline, queued)
    interrupted_handoff_expect_rows_match_outgoing(queued)
    interrupted_handoff_expect_abort_reconciles!(report_root)
    interrupted_handoff_expect_money_unchanged(money_before)

    # The owner admits writes again, and a new entry's snapshot arrives.
    later_entry_ids = interrupted_handoff_companies.map { |company| interrupted_handoff_create_entry(company) }
    live_handoff_catch_up!
    expect(interrupted_handoff_projection(later_entry_ids).keys).to match_array(later_entry_ids)
  end

  it "resumes a rollback interrupted before freeze and applies each queued snapshot exactly once" do
    with_live_handoff do
      queued = interrupted_handoff_queue_snapshots!
      money_before = interrupted_handoff_money
      baseline = TimekeepingLiveHandoff.snapshot_receipt_baseline
      report_root = live_handoff_report_root

      interrupted_handoff_interrupt_before_freeze!(report_root, queued)
      interrupted_handoff_refused_at_freeze!(report_root, queued)

      live_handoff_resume_relay
      interrupted_handoff_run(report_root:)

      interrupted_handoff_expect_resumed!(report_root:, queued:, baseline:, money_before:)
      interrupted_handoff_expect_second_resume_changes_nothing!(report_root)
      interrupted_handoff_expect_redelivery_answers!(queued, baseline)
    end
  end

  it "aborts a rollback interrupted before freeze: it waits while the relay is paused, then drains before " \
     "reopening writes" do
    with_live_handoff do
      queued = interrupted_handoff_queue_snapshots!
      money_before = interrupted_handoff_money
      baseline = TimekeepingLiveHandoff.snapshot_receipt_baseline
      report_root = live_handoff_report_root

      interrupted_handoff_interrupt_before_freeze!(report_root, queued)
      # P is stored before the abort starts: an abort with P unset would
      # store it itself, so the row could not be unchanged.
      final_outbox_position = interrupted_handoff_refused_at_freeze!(report_root, queued)
      held_row = TimekeepingLiveHandoff.ownership_row_text
      held_admission = interrupted_handoff_admission_text

      polls = []
      during_wait = {}
      sleeper = interrupted_handoff_counting_sleeper(polls) do |poll|
        during_wait[poll] = { row: TimekeepingLiveHandoff.ownership_row_text, admission: interrupted_handoff_admission_text,
                              billing: interrupted_handoff_billing_writes }
        live_handoff_resume_relay if poll == 2
      end
      # after_step freeze is reported before the abort clears the step and
      # admits the outgoing owner, so this is the moment before writes reopen.
      before_reopen = {}
      observer = interrupted_handoff_observer do |event, step|
        next unless event == :after_step && step == "freeze"

        before_reopen[:delivery] = interrupted_handoff_delivery(queued, through: final_outbox_position)
        before_reopen[:billing] = interrupted_handoff_billing_writes
      end

      interrupted_handoff_run(report_root:, abort: true, observer:, sleeper:)

      expect(polls.size).to be >= 2
      expect(polls).to all(eq(Timekeeping::Handoff::Runner::ABORT_POLL_INTERVAL))
      [1, 2].each do |poll|
        expect(during_wait.fetch(poll).fetch(:row)).to eq(held_row), "ownership row at poll #{poll}"
        expect(during_wait.fetch(poll).fetch(:admission)).to eq(held_admission), "admission at poll #{poll}"
        expect(during_wait.fetch(poll).fetch(:billing)).to eq(interrupted_handoff_billing_refused), "billing at poll #{poll}"
      end
      interrupted_handoff_expect_delivered(before_reopen.fetch(:delivery), queued)
      expect(before_reopen.fetch(:billing)).to eq(interrupted_handoff_billing_refused)

      interrupted_handoff_expect_aborted!(report_root:, queued:, baseline:, money_before:)
    end
  end

  it "resumes a rollback interrupted during checkpoint, after freeze drained the queue" do
    with_live_handoff do
      queued = interrupted_handoff_queue_snapshots!
      money_before = interrupted_handoff_money
      report_root = live_handoff_report_root

      final_outbox_position = interrupted_handoff_refused_at_freeze!(report_root, queued)
      # Taken before the relay resumes, because resuming lets it deliver.
      baseline = TimekeepingLiveHandoff.snapshot_receipt_baseline
      live_handoff_resume_relay
      interrupted_handoff_interrupt_during_checkpoint!(report_root, queued, through: final_outbox_position)

      interrupted_handoff_run(report_root:)

      interrupted_handoff_expect_resumed!(report_root:, queued:, baseline:, money_before:)
      interrupted_handoff_expect_second_resume_changes_nothing!(report_root)
      interrupted_handoff_expect_redelivery_answers!(queued, baseline)
    end
  end

  # The abort owes no step here, because freeze is recorded, so it admits at
  # once; the before-freeze abort above is what proves the drain comes before
  # writes reopen.
  it "aborts a rollback interrupted during checkpoint and returns ownership to Timekeeping" do
    with_live_handoff do
      queued = interrupted_handoff_queue_snapshots!
      money_before = interrupted_handoff_money
      report_root = live_handoff_report_root

      final_outbox_position = interrupted_handoff_refused_at_freeze!(report_root, queued)
      baseline = TimekeepingLiveHandoff.snapshot_receipt_baseline
      live_handoff_resume_relay
      interrupted_handoff_interrupt_during_checkpoint!(report_root, queued, through: final_outbox_position)

      interrupted_handoff_run(report_root:, abort: true)

      interrupted_handoff_expect_aborted!(report_root:, queued:, baseline:, money_before:)
    end
  end
end

# frozen_string_literal: true

require "rails_helper"
require "digest"
require "fileutils"
require "json"
require "tmpdir"

# Proves the handoff's concurrency rules against the started demo runtime: the
# monolith's test database, a real Timekeeping server and database, and the
# real owner integrations config/initializers/timekeeping_handoff.rb builds.
# Every handoff runs through Timekeeping::Handoff::Runner.run with the
# configured owners. Each example starts in the legacy owner state and runs a
# real cutover first, because the "timekeeping" owner state leaves the
# Timekeeping database holding only its admission row.
#
# The runtime harness activates the queue ledger before the launcher starts,
# so any job a non-dedicated worker runs during these examples fails the
# suite at teardown.
RSpec.describe "Timekeeping handoff concurrency", :integrated_runtime, :two_tenant_seed, type: :request,
                                                                                       committed_data: true do
  # The runtime's readiness checks and the handoff's Timekeeping calls go to
  # 127.0.0.1. An around hook wraps the suite's before hooks, so this is in
  # place before the integrated runtime hook boots the launcher.
  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true)
    example.run
  ensure
    # Back to the suite default (spec/rails_helper.rb), so no later spec may reach localhost.
    WebMock.disable_net_connect!
  end

  # Points the handoff integrations at this example's runtime for the block,
  # then rebuilds them from ENV again once ENV is restored. The runtime's
  # signing key comes too: an in-process invoice save signs its reservation
  # requests, and an entry write signs its user token, with that key.
  def concurrency_with_runtime_env(&block)
    runtime_env = @integrated_runtime.credentials.to_env.merge(
      Timekeeping::EntryApiClient::BASE_URL_ENV => @integrated_runtime.timekeeping_url,
      Internal::V1::BaseController::SERVICE_TOKEN_ENV => @integrated_runtime.credentials.service_token
    )
    with_timekeeping_env(runtime_env) do
      concurrency_rebuild_integrations
      block.call
    end
  ensure
    concurrency_rebuild_integrations
  end

  # Reruns only the initializer's own code, so the integrations it builds read
  # the URL and token in ENV now. Rerunning every to_prepare hook would reload
  # FactoryBot, which fails on the seed's top-level helper methods.
  def concurrency_rebuild_integrations
    allow(Rails.application.config).to receive(:to_prepare).and_yield
    load Rails.root.join("config/initializers/timekeeping_handoff.rb").to_s
  end

  # Runs one handoff call into report_root, which a resumed handoff must share
  # with the call it resumes: the step 2 money snapshot is kept there.
  def concurrency_run_handoff(direction, report_root:, observer: Timekeeping::Handoff::NullObserver.new)
    Timekeeping::Handoff::Runner.run(direction:, report_root:, observer:)
  end

  def concurrency_report_root
    Pathname(Dir.mktmpdir("timekeeping-handoff-concurrency")).tap { |root| (@concurrency_report_roots ||= []) << root }
  end

  def concurrency_remove_report_roots
    Array(@concurrency_report_roots).each { |root| FileUtils.rm_rf(root) }
  end

  def concurrency_stored_ownership
    TimekeepingOwnership.uncached do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:owner, :handoff_step)
    end
  end

  # A company owner whose current workspace is that company, so requests made
  # as them act on it.
  def concurrency_owner_of(company)
    User.with_role(:owner, company).find_by!(current_workspace_id: company.id)
  end

  # Copper Kettle's seed has no draft invoice, so any kept one serves: the
  # update and discard are refused before any check of the invoice's state.
  def concurrency_kept_invoice(company)
    company.invoices.kept.order(:id).first!
  end

  # One digest of every invoice, line and outbox row of the company, read
  # fresh from the database, so any write a refused request made changes it.
  def concurrency_billing_digest(company)
    connection = ActiveRecord::Base.connection
    company_id = connection.quote(company.id)
    rows = {
      invoices: "SELECT * FROM invoices WHERE company_id = #{company_id} ORDER BY id",
      lines: "SELECT invoice_line_items.* FROM invoice_line_items JOIN invoices ON invoices.id = " \
             "invoice_line_items.invoice_id WHERE invoices.company_id = #{company_id} ORDER BY invoice_line_items.id",
      outbox: "SELECT * FROM invoice_operation_outbox_items WHERE company_id = #{company_id} ORDER BY id"
    }.transform_values { |sql| connection.uncached { connection.select_rows(sql) } }
    Digest::SHA256.hexdigest(JSON.generate(rows))
  end

  def concurrency_create_invoice(company, user)
    client = company.clients.kept.order(:id).first!
    params = {
      invoice: {
        client_id: client.id,
        invoice_number: "HANDOFF-CONCURRENCY-#{company.id}",
        issue_date: Date.current.iso8601,
        due_date: (Date.current + 7).iso8601,
        status: "draft",
        currency: company.base_currency,
        invoice_line_items_attributes: [
          { name: "Work", description: "Work", date: Date.current.iso8601, rate: 100, quantity: 60 }
        ]
      }
    }
    send_request :post, api_v1_invoices_path, params:, headers: auth_headers(user)
  end

  # Changes only the reference, so the save sends no reservation operation
  # and succeeds whenever billing writes are admitted.
  def concurrency_update_invoice(invoice, user, reference:)
    params = { invoice: { client_id: invoice.client_id, reference: } }
    send_request :patch, api_v1_invoice_path(invoice), params:, headers: auth_headers(user)
  end

  def concurrency_discard_invoice(invoice, user)
    send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(user)
  end

  # Sends create, update and discard as each company's owner, and checks each
  # answer is the handoff refusal and that the company's billing rows did not
  # change. aggregate_failures reports every refused write that went wrong.
  def concurrency_expect_billing_writes_refused(companies, held_at:)
    aggregate_failures("billing writes held at #{held_at}") do
      companies.each do |company|
        user = concurrency_owner_of(company)
        sign_in user
        invoice = concurrency_kept_invoice(company)
        writes = {
          create: -> { concurrency_create_invoice(company, user) },
          update: -> { concurrency_update_invoice(invoice, user, reference: "HELD") },
          discard: -> { concurrency_discard_invoice(invoice, user) }
        }
        writes.each do |name, write|
          digest_before = concurrency_billing_digest(company)
          write.call

          expect(response).to have_http_status(:service_unavailable), "#{company.name} #{name} at #{held_at}"
          expect(response.parsed_body["reason"]).to eq("ownership_moving"), "#{company.name} #{name} at #{held_at}"
          expect(concurrency_billing_digest(company)).to eq(digest_before), "#{company.name} #{name} at #{held_at}"
        end
      end
    end
  end

  # How long a lock wait or a backend pid may take to appear. Each check
  # returns as soon as the server reports it; this only bounds a failure.
  def concurrency_wait_seconds
    30
  end

  def concurrency_pop(queue, what)
    queue.pop(timeout: concurrency_wait_seconds) || raise("#{what} was not reported within #{concurrency_wait_seconds} s")
  end

  # Hands the entries to Timekeeping before each company's rollback: a real
  # cutover from legacy for the first company, a re-cutover after each
  # earlier rollback.
  def concurrency_hand_to_timekeeping(round)
    concurrency_run_handoff(round.zero? ? :cutover : :re_cutover, report_root: concurrency_report_root)
    expect(concurrency_stored_ownership).to eq(["timekeeping", nil])
  end

  # Runs a rollback on a thread with its own pooled connection, whose backend
  # pid goes to runner_pids. The thread's value is the Runner::Refused the run
  # raised, or nil once it reached the flip, so an example can assert what its
  # observer captured before it judges how the run ended.
  def concurrency_rollback_thread(runner_pids, observer: Timekeeping::Handoff::NullObserver.new)
    report_root = concurrency_report_root
    committed_data_thread(runner_pids) do
      concurrency_run_handoff(:rollback, report_root:, observer:)
      nil
    rescue Timekeeping::Handoff::Runner::Refused => refusal
      refusal
    end
  end

  def concurrency_timekeeping_database_url
    ENV.fetch(TimekeepingDatabaseReset::DATABASE_URL_KEY).tap { |url| TestDatabaseGuard.require_test_database_url!(url) }
  end

  def concurrency_with_timekeeping_database
    connection = PG.connect(concurrency_timekeeping_database_url)
    yield connection
  ensure
    connection&.close
  end

  # The pid of a Timekeeping server backend that waits on holding_pid's locks,
  # or nil when none does within the wait. Both test databases share one
  # PostgreSQL server, so a monolith connection outside the pool can read
  # the Timekeeping database's sessions and their lock waits.
  #
  # With during_step_one, only a wait seen while the monolith's ownership row
  # has not yet recorded a handoff step counts. Step 1 fences Timekeeping
  # before it records close_admission, so this tells the fence's wait apart
  # from a later step's wait on the same admission row, such as settle's.
  def concurrency_timekeeping_backend_blocked_by(holding_pid, during_step_one: false)
    observer = ActiveRecord::Base.connection_pool.db_config.new_connection
    database = URI(concurrency_timekeeping_database_url).path.delete_prefix("/")
    step_one = "AND EXISTS (SELECT 1 FROM #{TimekeepingOwnership.quoted_table_name} WHERE id = #{TimekeepingOwnership::SINGLETON_ID} " \
               "AND handoff_step IS NULL)"
    query = "SELECT pid FROM pg_stat_activity WHERE datname = #{observer.quote(database)} " \
            "AND #{observer.quote(holding_pid)} = ANY(pg_blocking_pids(pid)) #{step_one if during_step_one} " \
            "ORDER BY pid LIMIT 1"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + concurrency_wait_seconds
    loop do
      pid = observer.select_value(query)
      return pid if pid || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep CommittedDataMode::Helpers::BLOCKER_POLL_INTERVAL
    end
  ensure
    observer&.disconnect!
  end

  # Two new unbilled entries on one billable project of the company, written
  # while the legacy store still owns entries, so the first cutover carries
  # them to Timekeeping. The seed bills every entry it puts on a sent invoice
  # and puts every billable entry on some invoice, so no seeded entry is free
  # to reserve or edit. Returns the project's client and the entry ids.
  def concurrency_add_free_entries(company)
    project = Project.joins(:client).where(clients: { company_id: company.id }, billable: true).order(:id).first!
    user = project.project_members.order(:id).first!.user
    entry_ids = Array.new(2) do |days_back|
      TimesheetEntry.create!(user:, project:, work_date: Date.current - days_back, duration: 60,
                             note: "Handoff concurrency", bill_status: :unbilled).id
    end
    [project.client, entry_ids]
  end

  def concurrency_line(entry_id)
    { name: "Handoff concurrency", date: Date.current, rate: 100, quantity: 60, timesheet_entry_id: entry_id }
  end

  # A draft holding one entry, saved through the billing fence as the invoice
  # controller saves it. Its save commits a holding row for the invoice.
  def concurrency_create_draft(company, client, entry_id)
    Timekeeping::BillingFence.transaction do
      company.invoices.create!(client:, invoice_number: "HANDOFF-INFLIGHT-#{company.id}", issue_date: Date.current,
                               due_date: Date.current + 7, status: :draft,
                               invoice_line_items_attributes: [concurrency_line(entry_id)])
    end
  end

  # A session outside the pool that holds the invoice's holding row FOR
  # UPDATE. A save writes that row (Invoices::OperationCoordinator#settle) only
  # after reservations.prepare returns, so the save stops there with its
  # pending intent committed, its reservation prepared and the ownership row
  # held FOR SHARE by its billing fence.
  def concurrency_hold_holding_row(invoice)
    holder = ActiveRecord::Base.connection_pool.db_config.new_connection
    holder.begin_db_transaction
    holder.execute("SELECT 1 FROM invoice_entry_holdings WHERE company_id = #{Integer(invoice.company_id)} " \
                   "AND invoice_id = #{Integer(invoice.id)} FOR UPDATE")
    holder
  end

  def concurrency_latest_intent(invoice)
    InvoiceOperationIntent.where(company_id: invoice.company_id, invoice_id: invoice.id).order(:id).last
  end

  # What settle still owes the in-flight save: its intent, and whether its
  # commit reached Timekeeping. Timekeeping was fenced before the save
  # committed and opens no settle step until settle runs, so the save's own
  # delivery is refused and left undelivered.
  def concurrency_settle_owed(invoice)
    intent = concurrency_latest_intent(invoice)
    commit = InvoiceOperationOutboxItem.find_by(company_id: invoice.company_id, operation_id: intent.operation_id,
                                                kind: "commit")
    { intent: intent.state, commit_recorded: !commit.nil?, commit_delivered: !commit&.delivered_at.nil? }
  end

  # The in-flight operation as both owners hold it: the monolith's intent,
  # and Timekeeping's operation and the invoice's reservations.
  def concurrency_operation_state(invoice)
    intent = concurrency_latest_intent(invoice)
    concurrency_with_timekeeping_database do |timekeeping|
      operation = timekeeping.exec_params(
        "SELECT state FROM invoice_operations WHERE company_id = $1 AND operation_id = $2",
        [invoice.company_id, intent.operation_id]
      ).column_values(0)
      reservations = timekeeping.exec_params(
        "SELECT entry_id, state FROM reservations WHERE company_id = $1 AND invoice_id = $2 ORDER BY entry_id",
        [invoice.company_id, invoice.id]
      ).values.map { |entry_id, state| [Integer(entry_id), state] }
      { intent: intent.state, operation:, reservations: }
    end
  end

  # Holds the entry's Timekeeping row FOR UPDATE on its own connection to the
  # Timekeeping database, reports that connection's backend pid and the
  # entry's version, and keeps the lock until release is pushed.
  def concurrency_hold_timekeeping_entry(company, entry_id, reported, release)
    concurrency_with_timekeeping_database do |timekeeping|
      timekeeping.exec("BEGIN")
      version = timekeeping.exec_params("SELECT version FROM entries WHERE company_id = $1 AND id = $2 FOR UPDATE",
                                        [company.id, entry_id]).getvalue(0, 0)
      reported << [Integer(timekeeping.exec("SELECT pg_backend_pid()").getvalue(0, 0)), Integer(version)]
      release.pop
      timekeeping.exec("COMMIT")
    end
  end

  # Sends the entry update straight to the Timekeeping server from a plain
  # thread, so it leases no pooled connection while it waits. The thread's
  # value is the HTTP response.
  def concurrency_update_entry_thread(company, entry_id:, version:, note:)
    token = Timekeeping::UserToken.mint(user: concurrency_owner_of(company), company:)
    path = format(Timekeeping::EntryWriteClient::ENTRY_PATH, company_id: company.id, entry_id:)
    uri = URI.join(@integrated_runtime.timekeeping_url, path)
    request = Net::HTTP::Patch.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Ownership-Generation"] = TimekeepingOwnership.current.generation.to_s
    request["Idempotency-Key"] = SecureRandom.uuid
    request["If-Match"] = version.to_s
    request["Content-Type"] = "application/json"
    request.body = JSON.generate("note" => note)
    Thread.new do
      Net::HTTP.start(uri.host, uri.port, read_timeout: concurrency_wait_seconds * 4) { |http| http.request(request) }
    end
  end

  it "refuses invoice create, update and discard on both companies with 503 ownership_moving while a rollback is held, " \
     "and admits them after the flip", owner_state: "legacy" do
    companies = [fork_and_leaf, copper_kettle]

    concurrency_with_runtime_env do
      concurrency_run_handoff(:cutover, report_root: concurrency_report_root)
      expect(concurrency_stored_ownership).to eq(["timekeeping", nil])

      rollback_root = concurrency_report_root
      expect do
        concurrency_run_handoff(:rollback, report_root: rollback_root,
                                           observer: TimekeepingHandoffHooks::Interrupt.new(at: :after_close_admission))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      expect(concurrency_stored_ownership).to eq(["timekeeping", "close_admission"])
      concurrency_expect_billing_writes_refused(companies, held_at: "after_close_admission")

      expect do
        concurrency_run_handoff(:rollback, report_root: rollback_root,
                                           observer: TimekeepingHandoffHooks::Interrupt.new(at: :after_settle))
      end.to raise_error(TimekeepingHandoffHooks::Interrupted)
      expect(concurrency_stored_ownership).to eq(["timekeeping", "settle"])
      concurrency_expect_billing_writes_refused(companies, held_at: "after_settle")

      concurrency_run_handoff(:rollback, report_root: rollback_root)
      expect(concurrency_stored_ownership).to eq(["monolith", nil])

      # The control: once the handoff has flipped, the same kind of write is admitted.
      company = companies.first
      user = concurrency_owner_of(company)
      sign_in user
      invoice = concurrency_kept_invoice(company)
      concurrency_update_invoice(invoice, user, reference: "ADMITTED")

      expect(response).to have_http_status(:ok)
      expect(invoice.reload.reference).to eq("ADMITTED")
    end
  ensure
    concurrency_remove_report_roots
  end

  it "makes step 1 of a rollback wait for an invoice save paused after prepare, and settles the save before the freeze, " \
     "on both companies", owner_state: "legacy" do
    companies = [fork_and_leaf, copper_kettle]
    free_entries = companies.index_with { |company| concurrency_add_free_entries(company) }

    concurrency_with_runtime_env do
      companies.each_with_index do |company, round|
        concurrency_hand_to_timekeeping(round)
        client, entry_ids = free_entries.fetch(company)
        invoice = concurrency_create_draft(company, client, entry_ids.first)
        expect(InvoiceEntryHolding.exists?(company_id: company.id, invoice_id: invoice.id)).to be(true)

        holder = concurrency_hold_holding_row(invoice)
        holder_pid = holder.select_value("SELECT pg_backend_pid()")
        save_pids = Queue.new
        save = committed_data_thread(save_pids) do
          Timekeeping::BillingFence.transaction do
            Invoice.find(invoice.id).update!(invoice_line_items_attributes: [concurrency_line(entry_ids.second)])
          end
        end
        save_pid = concurrency_pop(save_pids, "#{company.name} save backend")
        expect(blocked_by?(save_pid, holder_pid, within: concurrency_wait_seconds))
          .to be(true), "#{company.name}: the save did not pause on the held holding row"

        # The observer runs on the rollback's thread. It waits for the save
        # thread before settle, so settle never races the save's own delivery,
        # and only captures state; the assertions run once the rollback ends.
        captured = {}
        recorder = TimekeepingHandoffHooks::Recorder.new
        observer = lambda do |event, step:|
          recorder.call(event, step:)
          case [event, step.to_s]
          when [:before_step, "settle"]
            save.join
            captured[:settle] = concurrency_settle_owed(invoice)
          when [:before_step, "freeze"]
            captured[:freeze] = concurrency_operation_state(invoice)
          end
        end
        runner_pids = Queue.new
        rollback = concurrency_rollback_thread(runner_pids, observer:)
        runner_pid = concurrency_pop(runner_pids, "#{company.name} rollback backend")
        expect(blocked_by?(runner_pid, save_pid, within: concurrency_wait_seconds))
          .to be(true), "#{company.name}: step 1 of the rollback did not wait on the save's FOR SHARE lock"

        holder.disconnect!
        refusal = rollback.value

        expect(captured[:freeze]).to eq(
          { intent: "committed", operation: ["committed"], reservations: entry_ids.sort.map { |id| [id, "committed"] } }
        ), "#{company.name}: at the freeze the in-flight operation was not settled (#{refusal&.message})"
        expect(captured[:settle]).to eq({ intent: "committed", commit_recorded: true, commit_delivered: false })
        expect(refusal).to be_nil
        expect(recorder.events).to include([:before_step, "settle"], [:before_step, "freeze"])
        expect(concurrency_stored_ownership).to eq(["monolith", nil])
      ensure
        holder&.disconnect!
        stop_committed_data_threads(save, rollback)
      end
    end
  ensure
    concurrency_remove_report_roots
  end

  it "makes a rollback's step-1 fence wait for a running Timekeeping entry update and keeps the update in the checkpoint, " \
     "on both companies", owner_state: "legacy" do
    companies = [fork_and_leaf, copper_kettle]
    free_entry_ids = companies.index_with { |company| concurrency_add_free_entries(company).last.first }

    concurrency_with_runtime_env do
      companies.each_with_index do |company, round|
        concurrency_hand_to_timekeeping(round)
        entry_id = free_entry_ids.fetch(company)
        reported = Queue.new
        release = Queue.new
        entry_holder = committed_data_thread { concurrency_hold_timekeeping_entry(company, entry_id, reported, release) }
        holder_pid, version = concurrency_pop(reported, "#{company.name} entry holder")

        note = "Handoff concurrency #{company.id}"
        update = concurrency_update_entry_thread(company, entry_id:, version:, note:)
        update_pid = concurrency_timekeeping_backend_blocked_by(holder_pid)
        expect(update_pid).not_to be_nil, "#{company.name}: the entry update never waited on the held entry row"

        rollback = concurrency_rollback_thread(Queue.new)
        fence_pid = concurrency_timekeeping_backend_blocked_by(update_pid, during_step_one: true)
        expect(fence_pid).not_to be_nil, "#{company.name}: the rollback's step-1 fence did not wait on the entry update"
        expect(blocked_by?(fence_pid, update_pid, within: concurrency_wait_seconds)).to be(true)

        release << :release
        entry_holder.join
        expect(update.value.code).to eq("200")
        expect(rollback.value).to be_nil
        expect(concurrency_stored_ownership).to eq(["monolith", nil])

        # Rollback loads Timekeeping's checkpoint into the monolith's prepared
        # tables, which carry the checkpoint's own table names.
        loaded_note = ActiveRecord::Base.connection.select_value(
          "SELECT note FROM entries WHERE company_id = #{Integer(company.id)} AND id = #{Integer(entry_id)}"
        )
        expect(loaded_note).to eq(note)
      ensure
        release&.push(:release)
        stop_committed_data_threads(entry_holder, rollback)
        update&.join(concurrency_wait_seconds * 4)
      end
    end
  ensure
    concurrency_remove_report_roots
  end
end

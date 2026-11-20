# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "TimekeepingWriterLog section 10.1 parser input checks" do
  it "section_10_1_paths refuses an item whose only backticked .rb tokens are absolute paths" do
    # "In each item take every backticked token; keep it when it is a relative `.rb` path with an optional `:<digits>` suffix, and strip the suffix (`app/models/agent.rb:17` becomes `app/models/agent.rb`)."
    # "An item with no path raises, and an empty list raises."
    text = <<~MARKDOWN
      **Every writer goes through the gateway.** The writers are those of section 3.1:

      - the web controller (`app/controllers/api/v1/timesheet_entry_controller.rb`);
      - a hostile writer (`/etc/miru/writer.rb`);

      A later paragraph names `app/services/timekeeping/gateway.rb`.
    MARKDOWN

    expect { TimekeepingWriterLog.section_10_1_paths(text) }.to raise_error(ArgumentError)
  end
end

RSpec.describe "TimekeepingWriterLog section 10.1 parser token filter" do
  it "section_10_1_paths keeps only relative .rb paths and never reads past the list" do
    # "In each item take every backticked token; keep it when it is a relative `.rb` path with an optional `:<digits>` suffix, and strip the suffix (`app/models/agent.rb:17` becomes `app/models/agent.rb`)."
    # "Later paragraphs (which mention `app/services/timekeeping/gateway.rb`) must not be read."
    text = <<~MARKDOWN
      **Every writer goes through the gateway.** The writers are those of section 3.1:

      - the invoice boundary (`app/models/invoice.rb`, `/tmp/outside.rb`, `Invoice#update_timesheet_entry_status!`);
      - agent destroy (`app/models/agent.rb:17`), as the `detach-entries` command.

      The gateway (`app/services/timekeeping/gateway.rb`) is described here.
    MARKDOWN

    expect(TimekeepingWriterLog.section_10_1_paths(text)).to eq(%w[app/models/invoice.rb app/models/agent.rb])
  end
end

RSpec.describe "TimekeepingWriterLog verdict input checks" do
  it "violations treats a padded or re-cased mark as an unknown writer and refuses a near-miss state name" do
    # "A NULL or unknown writer is a violation in every state."
    rows = [
      { writer: "projection ", company_id: 1, op: "INSERT" },
      { writer: "Projection", company_id: 1, op: "UPDATE" },
      { writer: "projection", company_id: 1, op: "DELETE" }
    ]

    expect(TimekeepingWriterLog.violations(state: "timekeeping", rows: rows)).to eq(rows.first(2))

    # "An unknown state name raises."
    %w[Timekeeping legacy\  rollback_].each do |state|
      expect { TimekeepingWriterLog.violations(state: state, rows: []) }
        .to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/)
    end
  end
end

RSpec.describe "TimekeepingWriterLog company attribution", committed_data: true do
  # "INSERT, UPDATE and DELETE on timesheet_entries each log one row with the right op and company_id, DELETE reading OLD, including writes from another connection"
  it "logs each write with the company of the row it changed, never another company's, DELETE included" do
    connection = ActiveRecord::Base.connection

    TimekeepingWriterLog.guarding(connection) do
      first_entry = create(:timesheet_entry)
      second_entry = create(:timesheet_entry)
      first_company_id = first_entry.reload.company_id
      second_company_id = second_entry.reload.company_id
      expect(first_company_id).not_to be_nil
      expect(second_company_id).not_to be_nil
      expect(first_company_id).not_to eq(second_company_id)

      first_entry.update!(note: "changed in the first company")
      connection.execute("DELETE FROM timesheet_entries WHERE id = #{connection.quote(second_entry.id)}")

      logged = TimekeepingWriterLog.rows(connection).map { |row| [row.fetch(:op), row.fetch(:company_id)] }
      expect(logged).to eq(
        [
          ["INSERT", first_company_id],
          ["INSERT", second_company_id],
          ["UPDATE", first_company_id],
          ["DELETE", second_company_id]
        ]
      )
    end
  end
end

RSpec.describe "TimekeepingWriterLog company attribution across sessions", committed_data: true do
  # "INSERT, UPDATE and DELETE on timesheet_entries each log one row with the right op and company_id, DELETE reading OLD, including writes from another connection"
  it "logs a second connection's delete of another company's row with that row's company and session" do
    connection = ActiveRecord::Base.connection
    main_entry = create(:timesheet_entry)
    other_entry = create(:timesheet_entry)
    other_company_id = other_entry.reload.company_id
    expect(other_company_id).not_to eq(main_entry.reload.company_id)
    main_pid = connection.select_value("SELECT pg_backend_pid()")
    worker_pids = Queue.new

    TimekeepingWriterLog.guarding(connection) do
      worker = committed_data_thread(worker_pids) do
        worker_connection = ActiveRecord::Base.connection
        worker_connection.execute(
          "DELETE FROM timesheet_entries WHERE id = #{worker_connection.quote(other_entry.id)}"
        )
      end
      begin
        expect(worker.join(5)).to eq(worker), "the worker thread did not finish within 5 seconds"
      ensure
        stop_committed_data_threads(worker)
      end
      worker_pid = worker_pids.pop

      logged = TimekeepingWriterLog.rows(connection, include_backend_pid: true)
      expect(logged.size).to eq(1)
      expect(logged.first).to include(op: "DELETE", company_id: other_company_id, backend_pid: worker_pid)
      expect(logged.first.fetch(:backend_pid)).not_to eq(main_pid)
    end
  end
end

RSpec.describe "TimekeepingWriterLog install twice", committed_data: true do
  # "TimekeepingWriterLog.install! and remove! each succeed when run twice, and install twice logs a write once"
  it "install! run twice still logs one insert exactly once with its op and company_id" do
    connection = ActiveRecord::Base.connection
    begin
      TimekeepingWriterLog.install!(connection)
      TimekeepingWriterLog.install!(connection)

      entry = create(:timesheet_entry)
      company_id = entry.reload.company_id
      expect(company_id).not_to be_nil

      expect(TimekeepingWriterLog.rows(connection)).to eq([{ writer: nil, company_id:, op: "INSERT" }])
    ensure
      TimekeepingWriterLog.remove!(connection)
    end
  end
end

RSpec.describe "TimekeepingWriterLog writer marks", committed_data: true do
  # "Each logged row's writer is the writing session's `current_setting('miru.writer', true)`: a `SET LOCAL`
  # 'projection' write logs `projection`, a 'legacy_gateway' write logs `legacy_gateway`, and an unmarked write logs NULL"
  it "logs the writing session's miru.writer: projection, legacy_gateway, and NULL for a never-marked session" do
    connection = ActiveRecord::Base.connection
    entry = create(:timesheet_entry)
    fresh = nil
    begin
      TimekeepingWriterLog.install!(connection)

      ActiveRecord::Base.transaction do
        connection.execute("SET LOCAL miru.writer = 'projection'")
        entry.update!(note: "projection write")
      end
      ActiveRecord::Base.transaction do
        connection.execute("SET LOCAL miru.writer = 'legacy_gateway'")
        entry.update!(note: "legacy write")
      end

      # A connection opened outside the pool has never run SET LOCAL, so the setting reads NULL, not ''.
      fresh = ActiveRecord::Base.connection_pool.db_config.new_connection
      fresh.execute("UPDATE timesheet_entries SET note = 'unmarked write' WHERE id = #{entry.id}")

      writers = TimekeepingWriterLog.rows(connection).pluck(:writer)
      expect(writers.size).to eq(3)
      expect(writers[0]).to eq("projection")
      expect(writers[1]).to eq("legacy_gateway")
      expect(writers[2]).to be_nil
    ensure
      fresh&.disconnect!
      TimekeepingWriterLog.remove!(connection)
    end
  end
end

RSpec.describe "TimekeepingWriterLog update and delete", committed_data: true do
  # "INSERT, UPDATE and DELETE on timesheet_entries each log one row with the right op and company_id, DELETE reading OLD, including writes from another connection"
  it "logs UPDATE with company_id and DELETE with the company_id read from OLD" do
    connection = ActiveRecord::Base.connection
    entry = create(:timesheet_entry)
    company_id = entry.reload.company_id
    expect(company_id).not_to be_nil
    begin
      TimekeepingWriterLog.install!(connection)

      entry.update!(note: "changed")
      connection.execute("DELETE FROM timesheet_entries WHERE id = #{entry.id}")

      expect(TimekeepingWriterLog.rows(connection)).to eq(
        [
          { writer: nil, company_id:, op: "UPDATE" },
          { writer: nil, company_id:, op: "DELETE" }
        ]
      )
    ensure
      TimekeepingWriterLog.remove!(connection)
    end
  end
end

RSpec.describe "TimekeepingWriterLog second connection", committed_data: true do
  # "INSERT, UPDATE and DELETE on timesheet_entries each log one row with the right op and company_id, DELETE reading OLD, including writes from another connection"
  it "logs a write made on a second pooled connection with that connection's backend pid" do
    connection = ActiveRecord::Base.connection
    entry = create(:timesheet_entry)
    company_id = entry.reload.company_id
    pids = Queue.new
    worker = nil
    begin
      TimekeepingWriterLog.install!(connection)

      worker = committed_data_thread(pids) do
        ActiveRecord::Base.connection.execute("UPDATE timesheet_entries SET note = 'other session' WHERE id = #{entry.id}")
      end
      expect(worker.join(5)).to eq(worker), "the worker thread did not finish within 5 seconds"
      worker_pid = pids.pop

      rows = TimekeepingWriterLog.rows(connection, include_backend_pid: true)
      expect(rows).to eq([{ writer: nil, company_id:, op: "UPDATE", backend_pid: worker_pid }])
      expect(worker_pid).not_to eq(connection.select_value("SELECT pg_backend_pid()"))
    ensure
      stop_committed_data_threads(worker)
      TimekeepingWriterLog.remove!(connection)
    end
  end
end

RSpec.describe "TimekeepingWriterLog remove twice", committed_data: true do
  # "TimekeepingWriterLog.install! and remove! each succeed when run twice, and install twice logs a write once"
  it "remove! run twice succeeds and leaves no trigger, function or table" do
    connection = ActiveRecord::Base.connection
    TimekeepingWriterLog.install!(connection)

    expect { TimekeepingWriterLog.remove!(connection) }.not_to raise_error
    expect { TimekeepingWriterLog.remove!(connection) }.not_to raise_error

    expect(connection.select_value(<<~SQL)).to eq(0)
      SELECT count(*) FROM pg_trigger
      WHERE tgname = 'miru_writer_log_trigger' AND tgrelid = 'timesheet_entries'::regclass
    SQL
    expect(connection.select_value("SELECT count(*) FROM pg_proc WHERE proname = 'miru_writer_log_record'")).to eq(0)
    expect(connection.select_value("SELECT to_regclass('public.miru_writer_log') IS NULL")).to be(true)
  ensure
    # A failing remove! above must not leave the trigger on for later examples.
    TimekeepingWriterLog.remove!(ActiveRecord::Base.connection)
  end
end

RSpec.describe "TimekeepingWriterLog guarding", committed_data: true do
  # "Make `install!` and `remove!` safe to run twice, and call `remove!` in an `ensure`, so no trigger outlives the guard."
  it "guarding re-raises the block's error and leaves no trigger behind" do
    connection = ActiveRecord::Base.connection
    block_failure = Class.new(StandardError)
    installed_inside = nil

    expect do
      TimekeepingWriterLog.guarding(connection) do
        installed_inside = connection.select_value(
          "SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger'"
        )
        raise block_failure, "flow failed"
      end
    end.to raise_error(block_failure, "flow failed")

    expect(installed_inside).to eq(1)
    expect(connection.select_value("SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger'")).to eq(0)
    expect(connection.select_value("SELECT to_regclass('public.miru_writer_log') IS NULL")).to be(true)
  end
end

RSpec.describe "TimekeepingWriterLog.violations" do
  # "violations returns NULL, empty-string and unknown writers as violations in the legacy, timekeeping and rollback
  # states alike, allows only legacy_gateway in legacy and only projection in timekeeping and rollback, and raises on an
  # unknown state name"
  it "violations flags NULL, empty and unknown writers in every state and allows only the state's own writer" do
    writers = [nil, "", "someone_else", "legacy_gateway", "projection", "Projection"]
    rows = writers.map { |writer| { writer:, company_id: 7, op: "UPDATE" } }

    expected_violating_writers = {
      "legacy" => [nil, "", "someone_else", "projection", "Projection"],
      "timekeeping" => [nil, "", "someone_else", "legacy_gateway", "Projection"],
      "rollback" => [nil, "", "someone_else", "legacy_gateway", "Projection"]
    }

    expected_violating_writers.each do |state, violating|
      result = TimekeepingWriterLog.violations(state:, rows:)
      expect(result).to eq(rows.select { |row| violating.include?(row[:writer]) }), "state #{state}"
    end
  end
end

RSpec.describe "TimekeepingWriterLog.violations state check" do
  # "Use a frozen table of allowed writers per state, and raise ArgumentError naming the valid states for any other state,
  # as `TimekeepingOwnerState.fetch` in spec/support/timekeeping/owner_state.rb does."
  it "violations raises ArgumentError naming the valid states for an unknown state, even with no rows" do
    [[], [{ writer: "projection", company_id: 1, op: "INSERT" }]].each do |rows|
      [nil, "cutover", "Legacy"].each do |state|
        expect { TimekeepingWriterLog.violations(state:, rows:) }.to raise_error(ArgumentError) { |error|
          expect(error.message).to include("legacy", "timekeeping", "rollback")
        }
      end
    end
  end
end

RSpec.describe "TimekeepingWriterLog.section_10_1_paths on the design doc" do
  # "Today the list gives eight paths: ..." and "Later paragraphs (which mention `app/services/timekeeping/gateway.rb`) must not be read."
  it "section_10_1_paths reads exactly the eight writer paths of the real design doc" do
    text = Rails.root.join("docs/architecture/timekeeping-soa.md").read

    expect(TimekeepingWriterLog.section_10_1_paths(text)).to eq(
      %w[
        app/controllers/api/v1/timesheet_entry_controller.rb
        app/controllers/api/v1/timesheet_entry/bulk_action_controller.rb
        app/controllers/api/v1/cli/timesheet_entries_controller.rb
        app/controllers/api/v1/agent/timesheet_entries_controller.rb
        app/services/imports/harvest_time_entries_importer.rb
        app/models/invoice.rb
        app/models/invoice_line_item.rb
        app/models/agent.rb
      ]
    )
    expect { TimekeepingWriterLog.check_section_10_1!(text:) }.not_to raise_error
  end
end

RSpec.describe "TimekeepingWriterLog.section_10_1_paths parsing rule" do
  # "An item starts at a line beginning with `- `; each following non-blank line that starts with whitespace continues it.
  # The list ends at the first line that is neither." and "An item with no path raises, and an empty list raises."
  it "section_10_1_paths reads continuation lines, stops at the list end and raises on pathless items, empty lists and a missing heading" do
    heading = "**Every writer goes through the gateway.** The writers are:"
    text = <<~MD
      #{heading}

      - the agent destroy (`app/models/agent.rb:17`), as the `detach-entries` command;
      - the invoice boundary, replacing `Invoice#update_timesheet_entry_status!` and
        the callbacks in `app/models/invoice.rb` and `app/models/invoice_line_item.rb`;

      The gateway lives in `app/services/timekeeping/gateway.rb`.
    MD

    expect(TimekeepingWriterLog.section_10_1_paths(text))
      .to eq(%w[app/models/agent.rb app/models/invoice.rb app/models/invoice_line_item.rb])

    pathless = "#{heading}\n\n- the `detach-entries` command via `Invoice#update_timesheet_entry_status!`;\n"
    expect { TimekeepingWriterLog.section_10_1_paths(pathless) }.to raise_error(ArgumentError)

    empty_list = "#{heading}\n\nThe gateway lives in `app/services/timekeeping/gateway.rb`.\n"
    expect { TimekeepingWriterLog.section_10_1_paths(empty_list) }.to raise_error(ArgumentError)

    no_heading = "Some writers:\n\n- the agent (`app/models/agent.rb`);\n"
    expect { TimekeepingWriterLog.section_10_1_paths(no_heading) }.to raise_error(ArgumentError)
  end
end

RSpec.describe "TimekeepingWriterLog.check_section_10_1!" do
  # "The section 10.1 parser reads exactly the eight backticked paths of the real list, and a path missing from the constant or from the doc raises"
  it "check_section_10_1! raises naming a path missing from the writers or from the doc" do
    text = <<~MD
      **Every writer goes through the gateway.** The writers are:

      - the agent destroy (`app/models/agent.rb:17`);
      - the Harvest import (`app/services/imports/harvest_time_entries_importer.rb`);
    MD

    matching = {
      "app/models/agent.rb" => :agent_destroy,
      "app/services/imports/harvest_time_entries_importer.rb" => :harvest_import
    }
    expect { TimekeepingWriterLog.check_section_10_1!(text:, writers: matching) }.not_to raise_error

    missing_from_writers = matching.except("app/models/agent.rb")
    expect { TimekeepingWriterLog.check_section_10_1!(text:, writers: missing_from_writers) }
      .to raise_error(ArgumentError, %r{app/models/agent\.rb})

    missing_from_doc = matching.merge("app/models/invoice.rb" => :invoice_reservation)
    expect { TimekeepingWriterLog.check_section_10_1!(text:, writers: missing_from_doc) }
      .to raise_error(ArgumentError, %r{app/models/invoice\.rb})
  end
end

RSpec.describe "TimekeepingWriterLog.require_cases!" do
  # "`app/models/invoice.rb` and `app/models/invoice_line_item.rb` both map to `:invoice_reservation`." and
  # "`require_cases!(case_names)` (raises naming writer case names that have no case)"
  it "require_cases! raises naming a writer case with no case and maps both invoice paths to invoice_reservation" do
    writers = TimekeepingWriterLog::SECTION_10_1_WRITERS
    expect(writers.fetch("app/models/invoice.rb")).to eq(:invoice_reservation)
    expect(writers.fetch("app/models/invoice_line_item.rb")).to eq(:invoice_reservation)

    all_cases = writers.values.uniq
    expect(all_cases.size).to eq(7)
    expect { TimekeepingWriterLog.require_cases!(all_cases) }.not_to raise_error

    expect { TimekeepingWriterLog.require_cases!(all_cases - [:invoice_reservation]) }
      .to raise_error(ArgumentError, /invoice_reservation/)
  end
end

RSpec.describe "TimekeepingWriterLog" do
  # "Never add it under db/migrate or to db/schema.rb."
  it "keeps the writer log table, function and trigger out of db/schema.rb and db/migrate" do
    expect(TimekeepingWriterLog).to respond_to(:install!)

    sources = [Rails.root.join("db/schema.rb"), *Dir.glob(Rails.root.join("db/migrate/**/*.rb"))]
    offenders = sources.select do |path|
      text = File.read(path)
      %w[miru_writer_log miru_writer_log_record miru_writer_log_trigger].any? { |name| text.include?(name) }
    end

    expect(offenders).to eq([])
  end
end

RSpec.describe "TimekeepingWriterLog" do
  # "Leave `spec/services/timekeeping/projection_consumer_spec.rb` unchanged, because
  # `spec/meta/timekeeping_projection_consumer_specs_spec.rb` checks its trigger text."
  it "leaves the projection consumer spec's own TEMP trigger in place and unshared" do
    expect(TimekeepingWriterLog).to respond_to(:install!)

    text = File.read(Rails.root.join("spec/services/timekeeping/projection_consumer_spec.rb"))

    expect(text).to include("CREATE TEMP TABLE projection_writer_spec_log (entry_id bigint, writer text);")
    expect(text).to include("CREATE FUNCTION pg_temp.projection_writer_spec_record() RETURNS trigger AS $$")
    expect(text).to include("CREATE TRIGGER projection_writer_spec_trigger AFTER INSERT OR UPDATE ON timesheet_entries")
    expect(text).to include("current_setting('miru.writer', true)")
    expect(text).not_to include("TimekeepingWriterLog")
    expect(text).not_to include("miru_writer_log")
  end
end

RSpec.describe "TimekeepingWriterLog" do
  # "spec/meta/test_database_cleanup_reset_sites_spec.rb and bin/rubocop pass"
  it "bin/rubocop passes on the writer log support file and its meta spec" do
    support_file = "spec/support/timekeeping/writer_log.rb"
    expect(File).to exist(Rails.root.join(support_file))

    output, status = Open3.capture2e(
      "bin/rubocop", "--force-exclusion", support_file, "spec/meta/timekeeping_writer_log_spec.rb",
      chdir: Rails.root.to_s
    )

    expect(status).to be_success, output
  end
end

RSpec.describe "TimekeepingWriterLog crashed-run install", committed_data: true do
  # "TimekeepingWriterLog.install! and remove! each succeed when run twice, and install twice logs a write once"
  # A second install! meets the table, function and trigger the first one left, as the next run meets
  # what a run that crashed before remove! left. The catalog must still hold exactly one trigger.
  it "install! over an installed trigger leaves exactly one trigger in the catalog" do
    connection = ActiveRecord::Base.connection
    TimekeepingWriterLog.install!(connection)
    # A row the dead run logged must not reach the next guard's reads.
    connection.execute(
      "INSERT INTO public.miru_writer_log (writer, op, backend_pid) VALUES ('stale_run', 'UPDATE', 0)"
    )
    TimekeepingWriterLog.install!(connection)

    entry = create(:timesheet_entry)

    trigger_count = connection.select_value(
      "SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger' AND NOT tgisinternal"
    )
    expect(trigger_count).to eq(1)
    expect(TimekeepingWriterLog.rows(connection)).to eq([{ writer: nil, company_id: entry.company_id, op: "INSERT" }])
  ensure
    TimekeepingWriterLog.remove!(ActiveRecord::Base.connection)
  end
end

RSpec.describe "TimekeepingWriterLog cross-session logging", committed_data: true do
  # "INSERT, UPDATE and DELETE on timesheet_entries each log one row with the right op and company_id, DELETE reading OLD, including writes from another connection"
  # A TEMP table or pg_temp function would only see the installing session, so the logged pid must be the worker's.
  it "a projection write from another pooled connection is logged with that session's backend pid" do
    connection = ActiveRecord::Base.connection
    entry = create(:timesheet_entry)
    pids = Queue.new
    worker = nil

    TimekeepingWriterLog.guarding(connection) do
      worker = committed_data_thread(pids) do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL miru.writer = 'projection'")
          TimesheetEntry.find(entry.id).update!(note: "from worker")
        end
      end
      worker.join(5)
      stop_committed_data_threads(worker)

      worker_pid = pids.pop
      logged = TimekeepingWriterLog.rows(connection, include_backend_pid: true)

      expect(logged).to eq(
        [{ writer: "projection", company_id: entry.reload.company_id, op: "UPDATE", backend_pid: worker_pid }]
      )
      expect(worker_pid).not_to eq(connection.select_value("SELECT pg_backend_pid()"))
    end
  ensure
    stop_committed_data_threads(worker)
  end
end

RSpec.describe "TimekeepingWriterLog guarding failure", committed_data: true do
  # "Make `install!` and `remove!` safe to run twice, and call `remove!` in an `ensure`, so no trigger outlives the guard."
  it "guarding re-raises a failure after a logged write and leaves no trigger, function or table" do
    connection = ActiveRecord::Base.connection
    failure = Class.new(StandardError)

    expect do
      TimekeepingWriterLog.guarding(connection) do
        create(:timesheet_entry)
        raise failure, "flow failed mid-run"
      end
    end.to raise_error(failure, "flow failed mid-run")

    expect(connection.select_value("SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger'")).to eq(0)
    expect(connection.select_value("SELECT count(*) FROM pg_proc WHERE proname = 'miru_writer_log_record'")).to eq(0)
    expect(connection.select_value("SELECT to_regclass('miru_writer_log')")).to be_nil

    TimekeepingWriterLog.remove!(connection)
    expect(connection.select_value("SELECT to_regclass('miru_writer_log')")).to be_nil
  end
end

RSpec.describe "TimekeepingWriterLog.violations adversarial input" do
  # "An unknown state name raises."
  # "An unmarked, NULL, empty or unknown `miru.writer` write is a violation in the legacy, timekeeping and rollback states alike (not only after the first handoff)."
  it "violations raises for an unknown state with no rows and does not normalise near-miss writers" do
    %w[cutover Legacy].push(nil, "").each do |state|
      expect { TimekeepingWriterLog.violations(state: state, rows: []) }
        .to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/)
    end

    near_misses = ["Projection", " projection", "projection ", "LEGACY_GATEWAY", "legacy_gateway "].map do |writer|
      { writer: writer, company_id: 1, op: "UPDATE" }
    end
    expect(TimekeepingWriterLog.violations(state: "timekeeping", rows: near_misses)).to eq(near_misses)
    expect(TimekeepingWriterLog.violations(state: "legacy", rows: near_misses)).to eq(near_misses)
  end
end

RSpec.describe "TimekeepingWriterLog section 10.1 parser edges" do
  # "Later paragraphs (which mention `app/services/timekeeping/gateway.rb`) must not be read."
  # "An item with no path raises, and an empty list raises."
  it "section_10_1_paths stops at the list end and raises on a pathless item or an empty list" do
    heading = "**Every writer goes through the gateway.** The writers are those of section 3.1:"
    text = <<~DOC
      #{heading}

      - the agent destroy (`app/models/agent.rb:17`), as the `detach-entries` command;
      - the invoice boundary in `app/models/invoice.rb` and
        `app/models/invoice_line_item.rb` and `Invoice#update_timesheet_entry_status!`.

      The web controller writes through `app/services/timekeeping/gateway.rb`.
      - `app/models/late.rb`
    DOC
    expect(TimekeepingWriterLog.section_10_1_paths(text))
      .to eq(%w[app/models/agent.rb app/models/invoice.rb app/models/invoice_line_item.rb])

    pathless = "#{heading}\n\n- `Invoice#update_timesheet_entry_status!` as `detach-entries`\n"
    expect { TimekeepingWriterLog.section_10_1_paths(pathless) }.to raise_error(ArgumentError)

    empty = "#{heading}\n\nThe web controller writes through `app/services/timekeeping/gateway.rb`.\n"
    expect { TimekeepingWriterLog.section_10_1_paths(empty) }.to raise_error(ArgumentError)
  end
end

RSpec.describe "TimekeepingWriterLog clear!", committed_data: true do
  # "`clear!(connection = ActiveRecord::Base.connection)` empties the log with DELETE FROM." That it uses no
  # TRUNCATE is enforced by spec/meta/test_database_cleanup_reset_sites_spec.rb, which scans this support file.
  it "clear! empties the log and keeps the trigger live" do
    connection = ActiveRecord::Base.connection
    entry = create(:timesheet_entry)

    TimekeepingWriterLog.guarding(connection) do
      entry.update!(note: "before clear")
      expect(TimekeepingWriterLog.rows(connection).size).to eq(1)

      # Clearing twice in a row must not fail, and must not drop the table or the trigger.
      TimekeepingWriterLog.clear!(connection)
      TimekeepingWriterLog.clear!(connection)
      expect(TimekeepingWriterLog.rows(connection)).to eq([])

      entry.update!(note: "after clear")
      expect(TimekeepingWriterLog.rows(connection)).to eq(
        [{ writer: nil, company_id: entry.reload.company_id, op: "UPDATE" }]
      )
    end
  end
end

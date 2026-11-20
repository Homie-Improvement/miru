# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe TimekeepingWriterLog do
  context ".section_10_1_paths" do
    # "In each item take every backticked token; keep it when it is a relative `.rb` path with an optional `:<digits>` suffix, and strip the suffix (`app/models/agent.rb:17` becomes `app/models/agent.rb`)."
    # "An item starts at a line beginning with `- `; each following non-blank line that starts with whitespace continues it.
    # The list ends at the first line that is neither."
    # "Later paragraphs (which mention `app/services/timekeeping/gateway.rb`) must not be read."
    # "An item with no path raises, and an empty list raises."
    heading = "**Every writer goes through the gateway.** The writers are those of section 3.1:"

    parser_cases = [
      {
        name: "an item whose only .rb token is an absolute path",
        text: <<~MARKDOWN,
          #{heading}

          - the web controller (`app/controllers/api/v1/timesheet_entry_controller.rb`);
          - a hostile writer (`/etc/miru/writer.rb`);

          A later paragraph names `app/services/timekeeping/gateway.rb`.
        MARKDOWN
        raises: true
      },
      {
        name: "an absolute path and a method token beside relative paths, a :17 suffix and a later paragraph",
        text: <<~MARKDOWN,
          #{heading}

          - the invoice boundary (`app/models/invoice.rb`, `/tmp/outside.rb`, `Invoice#update_timesheet_entry_status!`);
          - agent destroy (`app/models/agent.rb:17`), as the `detach-entries` command.

          The gateway (`app/services/timekeeping/gateway.rb`) is described here.
        MARKDOWN
        paths: %w[app/models/invoice.rb app/models/agent.rb]
      },
      {
        name: "an indented continuation line and a stray bullet after a non-bullet paragraph",
        text: <<~MARKDOWN,
          #{heading}

          - the agent destroy (`app/models/agent.rb:17`), as the `detach-entries` command;
          - the invoice boundary in `app/models/invoice.rb` and
            `app/models/invoice_line_item.rb` and `Invoice#update_timesheet_entry_status!`.

          The web controller writes through `app/services/timekeeping/gateway.rb`.
          - `app/models/late.rb`
        MARKDOWN
        paths: %w[app/models/agent.rb app/models/invoice.rb app/models/invoice_line_item.rb]
      },
      {
        name: "an item with only non-path backticked tokens",
        text: "#{heading}\n\n- `Invoice#update_timesheet_entry_status!` as `detach-entries`\n",
        raises: true
      },
      {
        name: "an item with a non-path command named in prose",
        text: "#{heading}\n\n- the `detach-entries` command via `Invoice#update_timesheet_entry_status!`;\n",
        raises: true
      },
      {
        name: "an empty list",
        text: "#{heading}\n\nThe web controller writes through `app/services/timekeeping/gateway.rb`.\n",
        raises: true
      },
      {
        name: "a missing heading",
        text: "Some writers:\n\n- the agent (`app/models/agent.rb`);\n",
        raises: true
      }
    ].map(&:freeze).freeze

    parser_cases.each do |parser_case|
      if parser_case[:raises]
        it "raises ArgumentError on #{parser_case[:name]}" do
          expect { described_class.section_10_1_paths(parser_case[:text]) }.to raise_error(ArgumentError)
        end
      else
        it "reads only the relative list paths from #{parser_case[:name]}" do
          expect(described_class.section_10_1_paths(parser_case[:text])).to eq(parser_case[:paths])
        end
      end
    end

    # "Today the list gives eight paths: ..." and "Later paragraphs (which mention `app/services/timekeeping/gateway.rb`) must not be read."
    it "reads exactly the eight writer paths of the real design doc" do
      text = Rails.root.join("docs/architecture/timekeeping-soa.md").read

      expect(described_class.section_10_1_paths(text)).to eq(
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
      expect { described_class.check_section_10_1!(text:) }.not_to raise_error
    end
  end

  context ".violations" do
    # "An unknown state name raises." and "Use a frozen table of allowed writers per state, and raise ArgumentError naming
    # the valid states for any other state, as `TimekeepingOwnerState.fetch` in spec/support/timekeeping/owner_state.rb does."
    unknown_states = [nil, "", "cutover", "Legacy", "Timekeeping", "legacy ", "rollback_"].freeze
    row_sets = {
      "no rows" => [].freeze,
      "one row" => [{ writer: "projection", company_id: 1, op: "INSERT" }.freeze].freeze
    }.freeze

    unknown_states.each do |state|
      row_sets.each do |row_label, rows|
        it "raises ArgumentError naming legacy, timekeeping and rollback for state #{state.inspect} with #{row_label}" do
          expect { described_class.violations(state:, rows:) }
            .to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/)
        end
      end
    end

    # "violations returns NULL, empty-string and unknown writers as violations in the legacy, timekeeping and rollback
    # states alike, allows only legacy_gateway in legacy and only projection in timekeeping and rollback"
    it "flags NULL, empty and unknown writers in every state and allows only the state's own writer" do
      writers = [nil, "", "someone_else", "legacy_gateway", "projection", "Projection"]
      rows = writers.map { |writer| { writer:, company_id: 7, op: "UPDATE" } }

      expected_violating_writers = {
        "legacy" => [nil, "", "someone_else", "projection", "Projection"],
        "timekeeping" => [nil, "", "someone_else", "legacy_gateway", "Projection"],
        "rollback" => [nil, "", "someone_else", "legacy_gateway", "Projection"]
      }

      expected_violating_writers.each do |state, violating|
        result = described_class.violations(state:, rows:)
        expect(result).to eq(rows.select { |row| violating.include?(row[:writer]) }), "state #{state}"
      end
    end

    # "A NULL or unknown writer is a violation in every state." The marks are compared exactly, never normalised.
    near_miss_writers = ["Projection", " projection", "projection ", "LEGACY_GATEWAY", "legacy_gateway "].freeze

    %w[timekeeping legacy].each do |state|
      near_miss_writers.each do |writer|
        it "counts the padded or re-cased writer #{writer.inspect} as a violation in #{state}" do
          rows = [{ writer:, company_id: 1, op: "UPDATE" }]

          expect(described_class.violations(state:, rows:)).to eq(rows)
        end
      end
    end

    it "flags a padded INSERT and a re-cased UPDATE but allows an exact projection DELETE in timekeeping" do
      rows = [
        { writer: "projection ", company_id: 1, op: "INSERT" },
        { writer: "Projection", company_id: 1, op: "UPDATE" },
        { writer: "projection", company_id: 1, op: "DELETE" }
      ]

      expect(described_class.violations(state: "timekeeping", rows:)).to eq(rows.first(2))
    end
  end

  context ".check_section_10_1!" do
    # "The section 10.1 parser reads exactly the eight backticked paths of the real list, and a path missing from the constant or from the doc raises"
    it "raises naming a path missing from the writers or from the doc" do
      text = <<~MD
        **Every writer goes through the gateway.** The writers are:

        - the agent destroy (`app/models/agent.rb:17`);
        - the Harvest import (`app/services/imports/harvest_time_entries_importer.rb`);
      MD

      matching = {
        "app/models/agent.rb" => :agent_destroy,
        "app/services/imports/harvest_time_entries_importer.rb" => :harvest_import
      }
      expect { described_class.check_section_10_1!(text:, writers: matching) }.not_to raise_error

      missing_from_writers = matching.except("app/models/agent.rb")
      expect { described_class.check_section_10_1!(text:, writers: missing_from_writers) }
        .to raise_error(ArgumentError, %r{app/models/agent\.rb})

      missing_from_doc = matching.merge("app/models/invoice.rb" => :invoice_reservation)
      expect { described_class.check_section_10_1!(text:, writers: missing_from_doc) }
        .to raise_error(ArgumentError, %r{app/models/invoice\.rb})
    end
  end

  context ".require_cases!" do
    # "`app/models/invoice.rb` and `app/models/invoice_line_item.rb` both map to `:invoice_reservation`." and
    # "`require_cases!(case_names)` (raises naming writer case names that have no case)"
    it "raises naming a writer case with no case and maps both invoice paths to invoice_reservation" do
      writers = TimekeepingWriterLog::SECTION_10_1_WRITERS
      expect(writers.fetch("app/models/invoice.rb")).to eq(:invoice_reservation)
      expect(writers.fetch("app/models/invoice_line_item.rb")).to eq(:invoice_reservation)

      all_cases = writers.values.uniq
      expect(all_cases.size).to eq(7)
      expect { described_class.require_cases!(all_cases) }.not_to raise_error

      expect { described_class.require_cases!(all_cases - [:invoice_reservation]) }
        .to raise_error(ArgumentError, /invoice_reservation/)
    end
  end

  context ".install!", committed_data: true do
    # "TimekeepingWriterLog.install! and remove! each succeed when run twice, and install twice logs a write once"
    # A second install! meets the table, function and trigger the first one left, as the next run meets
    # what a run that crashed before remove! left. The catalog must still hold exactly one trigger.
    it "crashed-run install: install! over an installed trigger leaves one trigger and logs a write once" do
      connection = ActiveRecord::Base.connection
      described_class.install!(connection)
      # A row the dead run logged must not reach the next guard's reads.
      connection.execute(
        "INSERT INTO public.miru_writer_log (writer, op, backend_pid) VALUES ('stale_run', 'UPDATE', 0)"
      )
      described_class.install!(connection)

      entry = create(:timesheet_entry)
      company_id = entry.reload.company_id
      expect(company_id).not_to be_nil

      trigger_count = connection.select_value(
        "SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger' AND NOT tgisinternal"
      )
      expect(trigger_count).to eq(1)
      expect(described_class.rows(connection)).to eq([{ writer: nil, company_id:, op: "INSERT" }])
    ensure
      described_class.remove!(ActiveRecord::Base.connection)
    end
  end

  context ".remove!", committed_data: true do
    # "TimekeepingWriterLog.install! and remove! each succeed when run twice, and install twice logs a write once"
    it "remove twice: remove! run twice succeeds and leaves no trigger, function or table" do
      connection = ActiveRecord::Base.connection
      described_class.install!(connection)

      expect { described_class.remove!(connection) }.not_to raise_error
      expect { described_class.remove!(connection) }.not_to raise_error

      expect(connection.select_value(<<~SQL)).to eq(0)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'miru_writer_log_trigger' AND tgrelid = 'timesheet_entries'::regclass
      SQL
      expect(connection.select_value("SELECT count(*) FROM pg_proc WHERE proname = 'miru_writer_log_record'")).to eq(0)
      expect(connection.select_value("SELECT to_regclass('public.miru_writer_log') IS NULL")).to be(true)
    ensure
      # A failing remove! above must not leave the trigger on for later examples.
      described_class.remove!(ActiveRecord::Base.connection)
    end
  end

  context ".guarding", committed_data: true do
    # "Make `install!` and `remove!` safe to run twice, and call `remove!` in an `ensure`, so no trigger outlives the guard."
    it "re-raises a failure after a logged write and leaves no trigger, function or table" do
      connection = ActiveRecord::Base.connection
      failure = Class.new(StandardError)
      installed_inside = nil

      expect do
        described_class.guarding(connection) do
          installed_inside = connection.select_value(
            "SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger'"
          )
          create(:timesheet_entry)
          raise failure, "flow failed mid-run"
        end
      end.to raise_error(failure, "flow failed mid-run")

      expect(installed_inside).to eq(1)
      expect(connection.select_value("SELECT count(*) FROM pg_trigger WHERE tgname = 'miru_writer_log_trigger'")).to eq(0)
      expect(connection.select_value("SELECT count(*) FROM pg_proc WHERE proname = 'miru_writer_log_record'")).to eq(0)
      expect(connection.select_value("SELECT to_regclass('public.miru_writer_log') IS NULL")).to be(true)

      described_class.remove!(connection)
      expect(connection.select_value("SELECT to_regclass('public.miru_writer_log') IS NULL")).to be(true)
    end
  end

  context ".rows", committed_data: true do
    # "INSERT, UPDATE and DELETE on timesheet_entries each log one row with the right op and company_id, DELETE reading OLD, including writes from another connection"
    it "logs each write with the company of the row it changed, never another company's, DELETE reading OLD" do
      connection = ActiveRecord::Base.connection

      described_class.guarding(connection) do
        first_entry = create(:timesheet_entry)
        second_entry = create(:timesheet_entry)
        first_company_id = first_entry.reload.company_id
        second_company_id = second_entry.reload.company_id
        expect(first_company_id).not_to be_nil
        expect(second_company_id).not_to be_nil
        expect(first_company_id).not_to eq(second_company_id)

        first_entry.update!(note: "changed in the first company")
        connection.execute("DELETE FROM timesheet_entries WHERE id = #{connection.quote(second_entry.id)}")

        expect(described_class.rows(connection)).to eq(
          [
            { writer: nil, company_id: first_company_id, op: "INSERT" },
            { writer: nil, company_id: second_company_id, op: "INSERT" },
            { writer: nil, company_id: first_company_id, op: "UPDATE" },
            { writer: nil, company_id: second_company_id, op: "DELETE" }
          ]
        )
      end
    end

    # "Each logged row's writer is the writing session's `current_setting('miru.writer', true)`: a `SET LOCAL`
    # 'projection' write logs `projection`, a 'legacy_gateway' write logs `legacy_gateway`, and an unmarked write logs NULL"
    it "logs the writing session's miru.writer: projection, legacy_gateway, and NULL for a never-marked session" do
      connection = ActiveRecord::Base.connection
      entry = create(:timesheet_entry)
      fresh = nil
      begin
        described_class.install!(connection)

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

        writers = described_class.rows(connection).pluck(:writer)
        expect(writers.size).to eq(3)
        expect(writers[0]).to eq("projection")
        expect(writers[1]).to eq("legacy_gateway")
        expect(writers[2]).to be_nil
      ensure
        fresh&.disconnect!
        described_class.remove!(connection)
      end
    end

    # A TEMP table or pg_temp function would only see the installing session, so every logged pid must be the worker's.
    it "logs a second connection's unmarked UPDATE, projection UPDATE and other-company DELETE with that session's pid" do
      connection = ActiveRecord::Base.connection
      main_entry = create(:timesheet_entry)
      other_entry = create(:timesheet_entry)
      main_company_id = main_entry.reload.company_id
      other_company_id = other_entry.reload.company_id
      expect(other_company_id).not_to eq(main_company_id)
      main_pid = connection.select_value("SELECT pg_backend_pid()")
      worker_pids = Queue.new

      described_class.guarding(connection) do
        worker = committed_data_thread(worker_pids) do
          worker_connection = ActiveRecord::Base.connection
          worker_connection.execute(
            "UPDATE timesheet_entries SET note = 'other session' WHERE id = #{worker_connection.quote(main_entry.id)}"
          )
          ActiveRecord::Base.transaction do
            worker_connection.execute("SET LOCAL miru.writer = 'projection'")
            TimesheetEntry.find(main_entry.id).update!(note: "from worker")
          end
          worker_connection.execute(
            "DELETE FROM timesheet_entries WHERE id = #{worker_connection.quote(other_entry.id)}"
          )
        end
        begin
          expect(worker.join(5)).to eq(worker), "the worker thread did not finish within 5 seconds"
        ensure
          # Stop the worker before guarding's remove! drops the trigger it may still be writing through.
          stop_committed_data_threads(worker)
        end
        worker_pid = worker_pids.pop

        expect(described_class.rows(connection, include_backend_pid: true)).to eq(
          [
            { writer: nil, company_id: main_company_id, op: "UPDATE", backend_pid: worker_pid },
            { writer: "projection", company_id: main_company_id, op: "UPDATE", backend_pid: worker_pid },
            { writer: nil, company_id: other_company_id, op: "DELETE", backend_pid: worker_pid }
          ]
        )
        expect(worker_pid).not_to eq(main_pid)
      end
    end
  end

  context ".clear!", committed_data: true do
    # "`clear!(connection = ActiveRecord::Base.connection)` empties the log with DELETE FROM." That it uses no
    # TRUNCATE is enforced by spec/meta/test_database_cleanup_reset_sites_spec.rb, which scans this support file.
    it "empties the log and keeps the trigger live" do
      connection = ActiveRecord::Base.connection
      entry = create(:timesheet_entry)

      described_class.guarding(connection) do
        entry.update!(note: "before clear")
        expect(described_class.rows(connection).size).to eq(1)

        # Clearing twice in a row must not fail, and must not drop the table or the trigger.
        described_class.clear!(connection)
        described_class.clear!(connection)
        expect(described_class.rows(connection)).to eq([])

        entry.update!(note: "after clear")
        expect(described_class.rows(connection)).to eq(
          [{ writer: nil, company_id: entry.reload.company_id, op: "UPDATE" }]
        )
      end
    end
  end

  context "repository boundaries" do
    # "Never add it under db/migrate or to db/schema.rb."
    it "keeps the writer log table, function and trigger out of db/schema.rb and db/migrate" do
      sources = [Rails.root.join("db/schema.rb"), *Dir.glob(Rails.root.join("db/migrate/**/*.rb"))]
      offenders = sources.select do |path|
        text = File.read(path)
        %w[miru_writer_log miru_writer_log_record miru_writer_log_trigger].any? { |name| text.include?(name) }
      end

      expect(offenders).to eq([])
    end

    # "Leave `spec/services/timekeeping/projection_consumer_spec.rb` unchanged, because
    # `spec/meta/timekeeping_projection_consumer_specs_spec.rb` checks its trigger text."
    it "leaves the projection consumer spec's own TEMP trigger in place and unshared" do
      text = File.read(Rails.root.join("spec/services/timekeeping/projection_consumer_spec.rb"))

      expect(text).to include("CREATE TEMP TABLE projection_writer_spec_log (entry_id bigint, writer text);")
      expect(text).to include("CREATE FUNCTION pg_temp.projection_writer_spec_record() RETURNS trigger AS $$")
      expect(text).to include("CREATE TRIGGER projection_writer_spec_trigger AFTER INSERT OR UPDATE ON timesheet_entries")
      expect(text).to include("current_setting('miru.writer', true)")
      expect(text).not_to include("TimekeepingWriterLog")
      expect(text).not_to include("miru_writer_log")
    end

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
end

# frozen_string_literal: true

require "rails_helper"
require "open3"
require "pg"

RSpec.describe "Timekeeping owner state harness" do
  # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI database in .github/workflows/validations.yml does. The error names only the database, never the URL."
  it "reset! refuses a non _test Timekeeping database before connecting and names only the database" do
    password = "sentinel-secret-9f2c"
    url = "postgres://harness_user:#{password}@127.0.0.1:1/timekeeping_demo"
    allow(PG).to receive(:connect).and_call_original

    error = nil
    begin
      TimekeepingDatabaseReset.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => url })
    rescue TestDatabaseGuard::NotATestDatabase => e
      error = e
    end

    expect(error).to be_a(TestDatabaseGuard::NotATestDatabase)
    expect(error.message).to include("timekeeping_demo")
    expect(error.message).not_to include(password)
    expect(error.message).not_to include("harness_user")
    expect(error.message).not_to include(url)
    expect(PG).not_to have_received(:connect)
  end
end

RSpec.describe "Timekeeping owner state harness" do
  # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI database in .github/workflows/validations.yml does. The error names only the database, never the URL."
  it "reset! with no state set still refuses a non _test database given in keyword form" do
    password = "sentinel-secret-41ab"
    conninfo = "host=127.0.0.1 port=1 user=harness_user password=#{password} dbname=timekeeping_test_backup"

    expect do
      TimekeepingDatabaseReset.reset!(nil, env: { "TIMEKEEPING_DATABASE_URL" => conninfo })
    end.to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
      expect(error.message).to include("timekeeping_test_backup")
      expect(error.message).not_to include(password)
    }
  end
end

RSpec.describe "Timekeeping owner state harness" do
  # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI database in .github/workflows/validations.yml does."
  it "require_test_database! accepts only names ending in _test" do
    expect(TestDatabaseGuard.require_test_database!("timekeeping_live_test")).to be_nil
    expect(TestDatabaseGuard.require_test_database!("timekeeping_runtime_test")).to be_nil

    ["timekeeping_demo", "timekeeping_test_copy", "timekeeping_TEST", "", nil].each do |name|
      expect { TestDatabaseGuard.require_test_database!(name) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase)
    end
  end
end

RSpec.describe "TimekeepingOwnerState.apply! persistence" do
  it "apply! of each state over a row with handoff_step freeze persists exactly that state's columns, and repeating it changes nothing" do
    # "`legacy` is owner monolith, `monolith_store` legacy, generation 1. `timekeeping` is owner timekeeping,
    # generation 2, `legacy_retired_at` set. `rollback` is owner monolith, store prepared, generation 3."
    # The timekeeping store and the rollback legacy_retired_at follow the plan's disclosed choices.
    expected = {
      "legacy" => { owner: "monolith", monolith_store: "legacy", generation: 1, retired: false },
      "timekeeping" => { owner: "timekeeping", monolith_store: "legacy", generation: 2, retired: true },
      "rollback" => { owner: "monolith", monolith_store: "prepared", generation: 3, retired: true }
    }
    read_row = lambda do
      row = TimekeepingOwnership.current
      {
        owner: row.owner, monolith_store: row.monolith_store, generation: row.generation,
        retired: !row.legacy_retired_at.nil?, handoff_step: row.handoff_step,
        final_outbox_position: row.final_outbox_position, legacy_retired_at: row.legacy_retired_at
      }
    end

    expected.each do |state_name, columns|
      TimekeepingOwnership.ensure_initial!
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)
                          .update_all(handoff_step: "freeze", generation: 9, final_outbox_position: 5)

      TimekeepingOwnerState.apply!(state_name)
      first = read_row.call

      expect(first.except(:legacy_retired_at))
        .to eq(columns.merge(handoff_step: nil, final_outbox_position: nil)), state_name

      TimekeepingOwnerState.apply!(state_name)

      expect(TimekeepingOwnership.count).to eq(1)
      expect(read_row.call).to eq(first), state_name
    end
  end
end

RSpec.describe "TimekeepingOwnerState.apply! refusal" do
  it "apply! of an unknown name raises ArgumentError and leaves the stored ownership row unchanged" do
    TimekeepingOwnership.ensure_initial!
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)
                        .update_all(handoff_step: "freeze", generation: 9)
    before = TimekeepingOwnership.current.attributes

    # "`TimekeepingOwnerState.apply!(state_name)` writes the row and raises `ArgumentError` on an unknown name."
    expect { TimekeepingOwnerState.apply!("bogus") }
      .to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/m)

    expect(TimekeepingOwnership.current.attributes).to eq(before)
  end
end

RSpec.describe "TimekeepingDatabaseReset.reset! guard" do
  it "reset! refuses a database whose name does not end in _test before connecting, naming only the database" do
    url = "postgres://guard_user:guard-secret-pw@127.0.0.1:5432/timekeeping_demo"
    allow(PG).to receive(:connect).and_call_original

    # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI
    # database in .github/workflows/validations.yml does. The error names only the database, never the URL."
    expect { TimekeepingDatabaseReset.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => url }) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).to include("timekeeping_demo")
        expect(error.message).not_to include("guard-secret-pw")
        expect(error.message).not_to include(url)
      }

    expect(PG).not_to have_received(:connect)
  end
end

RSpec.describe "TimekeepingDatabaseReset.reset! admission row" do
  it "reset! leaves exactly one admission row at each state's generation, and a repeated reset gives the same row" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    TestDatabaseGuard.require_test_database!(
      PG::Connection.conninfo_parse(url).find { |o| o[:keyword] == "dbname" }&.fetch(:val)
    )
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    # "Use the column default (generation 1) when no state is set and for legacy, generation 2 for timekeeping,
    # and null (fenced, because the monolith owns) for rollback."
    expected = { nil => "1", "legacy" => "1", "timekeeping" => "2", "rollback" => nil }

    connection = PG.connect(url)
    begin
      expected.each do |state_name, generation|
        connection.exec("DELETE FROM admission")
        connection.exec("INSERT INTO admission (id, generation) VALUES (1, 7)")

        2.times do
          TimekeepingDatabaseReset.reset!(state_name, env: { "TIMEKEEPING_DATABASE_URL" => url })

          rows = connection.exec("SELECT id, generation FROM admission").to_a
          expect(rows).to eq([{ "id" => "1", "generation" => generation }]), state_name.inspect
        end
      end
    ensure
      connection.close
    end
  end
end

RSpec.describe "TimekeepingOwnerState.selected" do
  it "selected accepts only the exact state names and returns nil only when the key is absent" do
    # "`TimekeepingOwnerState.selected(env)` returns nil only when the key is absent. Any value other than exactly
    # `legacy`, `timekeeping` or `rollback` raises `ArgumentError` and names all three. That includes an empty
    # string, mixed case and surrounding whitespace."
    expect(TimekeepingOwnerState.selected({})).to be_nil

    %w[legacy timekeeping rollback].each do |name|
      expect(TimekeepingOwnerState.selected({ "TIMEKEEPING_OWNER_STATE" => name })).to eq(name)
    end

    ["", "ROLLBACK", "rollback ", " legacy", "Timekeeping", "bogus"].each do |value|
      expect { TimekeepingOwnerState.selected({ "TIMEKEEPING_OWNER_STATE" => value }) }
        .to raise_error(ArgumentError) { |error|
          expect(error.message).to include("legacy", "timekeeping", "rollback")
        }
    end
  end
end

RSpec.describe "TimekeepingOwnerState.apply!" do
  it "apply! of each state over a row mid-handoff writes exactly that state's columns" do
    # "`legacy` is owner monolith, `monolith_store` legacy, generation 1. `timekeeping` is owner timekeeping,
    # generation 2, `legacy_retired_at` set. `rollback` is owner monolith, store prepared, generation 3."
    # The timekeeping store (legacy, the column default) and rollback keeping legacy_retired_at set are the
    # choices the change discloses.
    expected = {
      "legacy" => { owner: "monolith", monolith_store: "legacy", generation: 1, retired: false },
      "timekeeping" => { owner: "timekeeping", monolith_store: "legacy", generation: 2, retired: true },
      "rollback" => { owner: "monolith", monolith_store: "prepared", generation: 3, retired: true }
    }

    expected.each do |name, columns|
      TimekeepingOwnership.ensure_initial!
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)
                          .update_all(handoff_step: "freeze", generation: 9, final_outbox_position: 5,
                                      owner: "timekeeping", monolith_store: "prepared")

      TimekeepingOwnerState.apply!(name)

      row = TimekeepingOwnership.current
      expect(TimekeepingOwnership.count).to eq(1)
      expect(row.owner).to eq(columns[:owner]), name
      expect(row.monolith_store).to eq(columns[:monolith_store]), name
      expect(row.generation).to eq(columns[:generation]), name
      expect(row.handoff_step).to be_nil, name
      expect(row.final_outbox_position).to be_nil, name
      expect(row.legacy_retired_at.present?).to eq(columns[:retired]), name
    end
  end
end

RSpec.describe "TimekeepingOwnerState.apply! row handling" do
  it "apply! creates a missing row and refuses an unknown name without touching the row" do
    # "When the row is missing, it creates it first with `ensure_initial!`."
    TimekeepingOwnership.delete_all
    TimekeepingOwnerState.apply!("rollback")
    row = TimekeepingOwnership.current
    expect([row.owner, row.monolith_store, row.generation]).to eq(["monolith", "prepared", 3])

    # "`TimekeepingOwnerState.apply!(state_name)` writes the row and raises `ArgumentError` on an unknown name."
    ["bogus", "", "ROLLBACK", nil].each do |name|
      expect { TimekeepingOwnerState.apply!(name) }.to raise_error(ArgumentError)
    end
    row.reload
    expect([row.owner, row.monolith_store, row.generation]).to eq(["monolith", "prepared", 3])
  end
end

RSpec.describe "TimekeepingOwnerState.fetch" do
  it "fetch gives each state's admission generation and frozen rows" do
    # "Use the column default (generation 1) when no state is set and for legacy, generation 2 for timekeeping,
    # and null (fenced, because the monolith owns) for rollback."
    expect(TimekeepingOwnerState.fetch("legacy")[:admission_generation]).to eq(1)
    expect(TimekeepingOwnerState.fetch("timekeeping")[:admission_generation]).to eq(2)
    expect(TimekeepingOwnerState.fetch("rollback")[:admission_generation]).to be_nil

    %w[legacy timekeeping rollback].each do |name|
      expect(TimekeepingOwnerState.fetch(name)).to be_frozen
    end
    expect(TimekeepingOwnerState::STATES).to be_frozen
    expect { TimekeepingOwnerState.fetch("bogus") }.to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/m)
  end
end

RSpec.describe "expect_owner_state!" do
  it "expect_owner_state! passes on the applied state and fails once the generation changes" do
    %w[legacy timekeeping rollback].each do |name|
      TimekeepingOwnerState.apply!(name)
      expect { expect_owner_state!(name) }.not_to raise_error
    end

    # "It also compares owner, monolith_store, generation and whether legacy_retired_at is set, because
    # `EntryOwner.for` cannot tell generations apart."
    TimekeepingOwnerState.apply!("rollback")
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(generation: 4)
    expect(Timekeeping::EntryOwner.for(TimekeepingOwnership.current)).to eq(:prepared)
    expect { expect_owner_state!("rollback") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)

    TimekeepingOwnerState.apply!("timekeeping")
    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(legacy_retired_at: nil)
    expect { expect_owner_state!("timekeeping") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
  end
end

RSpec.describe "TimekeepingDatabaseReset.reset! guard" do
  it "reset! refuses a database not ending in _test before connecting and names only the database" do
    # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI
    # database in .github/workflows/validations.yml does. The error names only the database, never the URL."
    expect(PG).not_to receive(:connect)
    ["timekeeping_demo", "timekeeping_test_copy", "timekeeping_TEST"].each do |name|
      conninfo = "dbname=#{name} user=owner_state_demo_user password=owner-state-demo-secret"
      [nil, "legacy", "timekeeping", "rollback"].each do |state|
        expect { TimekeepingDatabaseReset.reset!(state, env: { "TIMEKEEPING_DATABASE_URL" => conninfo }) }
          .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
            expect(error.message).to include(name)
            expect(error.message).not_to include("owner-state-demo-secret")
            expect(error.message).not_to include("owner_state_demo_user")
          }
      end
    end

    expect { TestDatabaseGuard.require_test_database!(nil) }.to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect { TestDatabaseGuard.require_test_database!("") }.to raise_error(TestDatabaseGuard::NotATestDatabase)
    expect(TestDatabaseGuard.require_test_database!("timekeeping_test")).to be_nil
  end
end

RSpec.describe "TimekeepingDatabaseReset.reset! on the live Timekeeping database" do
  it "reset! empties the Timekeeping tables and leaves the admission row at each state's generation" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    TestDatabaseGuard.require_test_database!(
      PG::Connection.conninfo_parse(url).find { |option| option[:keyword] == "dbname" }&.fetch(:val)
    )
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                        "TIMEKEEPING_DATABASE_URL" => url, "DATABASE_URL" => nil },
                      "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
    end
    raise "db:prepare failed:\n#{output}" unless status.success?

    connection = PG.connect(url)
    migrations = connection.exec("SELECT count(*) FROM schema_migrations").getvalue(0, 0).to_i
    # "Use the column default (generation 1) when no state is set and for legacy, generation 2 for timekeeping,
    # and null (fenced, because the monolith owns) for rollback."
    { nil => 1, "legacy" => 1, "timekeeping" => 2, "rollback" => nil }.each do |state, generation|
      connection.exec("CREATE TABLE IF NOT EXISTS owner_state_reset_probe_rows (id integer)")
      connection.exec("INSERT INTO owner_state_reset_probe_rows (id) VALUES (1)")
      connection.exec("INSERT INTO admission (id, generation) VALUES (1, 7) " \
                      "ON CONFLICT (id) DO UPDATE SET generation = 7")

      expect(TimekeepingDatabaseReset.reset!(state, env: { "TIMEKEEPING_DATABASE_URL" => url })).to be_nil

      # "`reset!` deletes every table except ar_internal_metadata and schema_migrations."
      expect(connection.exec("SELECT count(*) FROM owner_state_reset_probe_rows").getvalue(0, 0).to_i).to eq(0)
      expect(connection.exec("SELECT count(*) FROM schema_migrations").getvalue(0, 0).to_i).to eq(migrations)
      rows = connection.exec("SELECT id, generation FROM admission").to_a
      expect(rows.size).to eq(1), state.inspect
      expect(rows.first["id"].to_i).to eq(1)
      expect(rows.first["generation"]&.to_i).to eq(generation), state.inspect
    end
  ensure
    connection&.exec("DROP TABLE IF EXISTS owner_state_reset_probe_rows")
    connection&.close
  end
end

RSpec.describe "TimekeepingDatabaseReset.reset! on a non-test database" do
  it "reset! refuses a real non-test database and leaves its rows in place" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    url = ENV.fetch("TIMEKEEPING_DATABASE_URL")
    options = PG::Connection.conninfo_parse(url).filter_map do |option|
      [option[:keyword], option[:val]] if option[:val]
    end.to_h
    TestDatabaseGuard.require_test_database!(options["dbname"])
    scratch_name = "timekeeping_owner_state_guard_scratch"
    admin = PG.connect(url)
    admin.exec("DROP DATABASE IF EXISTS #{scratch_name}")
    admin.exec("CREATE DATABASE #{scratch_name}")
    scratch_options = options.merge("dbname" => scratch_name)
    scratch = PG.connect(scratch_options)
    scratch.exec("CREATE TABLE kept_rows (id integer)")
    scratch.exec("INSERT INTO kept_rows (id) VALUES (1)")
    scratch_conninfo = scratch_options.map { |key, value| "#{key}='#{value.gsub(/['\\]/) { |c| "\\#{c}" }}'" }.join(" ")

    # "`reset!` refuses a database whose name does not end in `_test` and leaves its rows in place."
    expect { TimekeepingDatabaseReset.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => scratch_conninfo }) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /#{scratch_name}/o)
    expect(scratch.exec("SELECT count(*) FROM kept_rows").getvalue(0, 0).to_i).to eq(1)
  ensure
    scratch&.close
    admin&.exec("DROP DATABASE IF EXISTS #{scratch_name}") if scratch_name
    admin&.close
  end
end

RSpec.describe "TIMEKEEPING_OWNER_STATE probe run", :without_transaction do
  it "with TIMEKEEPING_OWNER_STATE=rollback an example after a committed_data example sees the rollback row" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/owner_state_probe.rb").to_s
    expect(File.basename(probe)).not_to end_with("_spec.rb")
    # "With `TIMEKEEPING_OWNER_STATE=rollback`, an example after a committed_data example sees owner monolith,
    # store prepared, generation 3"
    stdout, stderr, status = Open3.capture3({ "TIMEKEEPING_OWNER_STATE" => "rollback" },
                                            "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)

    expect(status).to be_success, "#{stdout}\n#{stderr}"
    expect(stdout).to include("2 examples, 0 failures")
    rollback = TimekeepingOwnerState.fetch("rollback")
    expect([rollback[:owner], rollback[:monolith_store], rollback[:generation]]).to eq(["monolith", "prepared", 3])
  end
end

RSpec.describe "TIMEKEEPING_OWNER_STATE bogus probe run", :without_transaction do
  it "with TIMEKEEPING_OWNER_STATE=bogus the run fails at load naming the three values" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/owner_state_probe.rb").to_s
    expect(File).to exist(probe)
    # "An unknown `TIMEKEEPING_OWNER_STATE` raises at load and names the three values."
    stdout, stderr, status = Open3.capture3({ "TIMEKEEPING_OWNER_STATE" => "bogus" },
                                            "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
    output = "#{stdout}\n#{stderr}"

    expect(status).not_to be_success
    expect(output).to include("ArgumentError")
    error_line = output.lines.find { |line| line.include?("ArgumentError") }
    expect(output).to match(/legacy.*timekeeping.*rollback/m)
    expect(output).to include("error occurred while loading").or include("errors occurred outside of examples")
    expect(error_line).not_to be_nil
  end
end

RSpec.describe "Timekeeping owner state selection across cleaner resets", :without_transaction do
  # "`TIMEKEEPING_OWNER_STATE` selects the legacy, timekeeping or rollback ownership state, an unknown value fails loudly, and the selected state survives every cleaner reset"
  it "the timekeeping and legacy states each survive the committed_data cleaner reset in a probe run" do
    probe = Rails.root.join("spec/fixtures/timekeeping_harness/owner_state_probe.rb").to_s

    %w[timekeeping legacy].each do |state|
      output, errors, status = Open3.capture3({ "TIMEKEEPING_OWNER_STATE" => state }, "bundle", "exec", "rspec", probe)

      expect(status.success?).to be(true), "#{state} probe failed:\n#{output}\n#{errors}"
      expect(output).to include("2 examples, 0 failures")
    end
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "reset! refuses a demo database name before connecting and never prints the URL or its password" do
    url = "postgres://demo_user:leakme-pw@db.invalid:5432/timekeeping_demo"
    expect(PG).not_to receive(:connect)
    expect(PG::Connection).not_to receive(:new)

    # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI database in .github/workflows/validations.yml does. The error names only the database, never the URL."
    %w[legacy timekeeping rollback].push(nil).each do |state|
      expect { TimekeepingDatabaseReset.reset!(state, env: { "TIMEKEEPING_DATABASE_URL" => url }) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).to include("timekeeping_demo")
          expect(error.message).not_to include("leakme-pw")
          expect(error.message).not_to include(url)
          expect(error.message).not_to include("db.invalid")
        }
    end
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "require_test_database! refuses names that only contain _test or have no name at all" do
    # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI database in .github/workflows/validations.yml does."
    [nil, "", "timekeeping_test_copy", "timekeeping_testing", "timekeeping_TEST", "timekeeping_test "].each do |name|
      expect { TestDatabaseGuard.require_test_database!(name) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase)
    end

    expect(TestDatabaseGuard.require_test_database!("timekeeping_live_test")).to be_nil
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "selected refuses blank, mixed-case and padded TIMEKEEPING_OWNER_STATE values and names the three states" do
    # "Any value other than exactly `legacy`, `timekeeping` or `rollback` raises `ArgumentError` and names all three. That includes an empty string, mixed case and surrounding whitespace."
    ["", "ROLLBACK", "rollback ", " legacy", "Timekeeping", "bogus"].each do |value|
      expect { TimekeepingOwnerState.selected({ "TIMEKEEPING_OWNER_STATE" => value }) }
        .to raise_error(ArgumentError) { |error|
          expect(error.message).to include("legacy", "timekeeping", "rollback")
        }
    end

    # "`TimekeepingOwnerState.selected(env)` returns nil only when the key is absent."
    expect(TimekeepingOwnerState.selected({})).to be_nil
    expect(TimekeepingOwnerState.selected({ "TIMEKEEPING_OWNER_STATE" => "rollback" })).to eq("rollback")
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "apply! over a mid-handoff row leaves no stale handoff column from the earlier state" do
    expected = {
      "legacy" => { owner: "monolith", monolith_store: "legacy", generation: 1, retired: false },
      "timekeeping" => { owner: "timekeeping", monolith_store: "legacy", generation: 2, retired: true },
      "rollback" => { owner: "monolith", monolith_store: "prepared", generation: 3, retired: true }
    }

    # "`legacy` is owner monolith, `monolith_store` legacy, generation 1. `timekeeping` is owner timekeeping, generation 2, `legacy_retired_at` set. `rollback` is owner monolith, store prepared, generation 3."
    expected.each do |state, columns|
      TimekeepingOwnership.ensure_initial!
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)
        .update_all(handoff_step: "freeze", generation: 9, final_outbox_position: 5,
                    owner: "timekeeping", monolith_store: "prepared", legacy_retired_at: nil)

      TimekeepingOwnerState.apply!(state)
      row = TimekeepingOwnership.current

      expect(row.owner).to eq(columns[:owner])
      expect(row.monolith_store).to eq(columns[:monolith_store])
      expect(row.generation).to eq(columns[:generation])
      expect(row.legacy_retired_at.present?).to eq(columns[:retired])
      expect(row.handoff_step).to be_nil
      expect(row.final_outbox_position).to be_nil
    end
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "apply! with an unknown or nil name raises and leaves the ownership row untouched" do
    TimekeepingOwnership.ensure_initial!
    TimekeepingOwnerState.apply!("rollback")
    before = TimekeepingOwnership.current.attributes

    # "`TimekeepingOwnerState.apply!(state_name)` writes the row and raises `ArgumentError` on an unknown name."
    ["bogus", "ROLLBACK", nil].each do |name|
      expect { TimekeepingOwnerState.apply!(name) }.to raise_error(ArgumentError)
    end

    expect(TimekeepingOwnership.current.attributes).to eq(before)
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "expect_owner_state! fails when only the generation differs from the rollback state" do
    TimekeepingOwnership.ensure_initial!
    TimekeepingOwnerState.apply!("rollback")
    expect { expect_owner_state!("rollback") }.not_to raise_error

    TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(generation: 4)

    # "It also compares owner, monolith_store, generation and whether legacy_retired_at is set, because `EntryOwner.for` cannot tell generations apart."
    expect { expect_owner_state!("rollback") }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError)
  end
end

RSpec.describe "Timekeeping owner state harness" do
  it "reset! does nothing when TIMEKEEPING_DATABASE_URL is absent, even for an unset state" do
    expect(PG).not_to receive(:connect)
    expect(PG::Connection).not_to receive(:new)

    # "`reset!` does nothing when `TIMEKEEPING_DATABASE_URL` is unset or the database does not exist yet."
    [nil, "legacy", "timekeeping", "rollback"].each do |state|
      expect(TimekeepingDatabaseReset.reset!(state, env: {})).to be_nil
    end

    expect do
      TimekeepingDatabaseReset.reset!("bogus", env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_test" })
    end.to raise_error(ArgumentError)
  end
end

RSpec.describe "TimekeepingDatabaseReset.reset! before the database exists" do
  it "reset! does nothing when the named _test database does not exist yet" do
    skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"

    options = PG::Connection.conninfo_parse(ENV.fetch("TIMEKEEPING_DATABASE_URL")).filter_map do |option|
      next if option[:val].nil? || option[:keyword] == "dbname"

      "#{option[:keyword]}='#{option[:val].gsub(/['\\]/) { |char| "\\#{char}" }}'"
    end
    missing = (options + ["dbname='timekeeping_owner_state_never_created_test'"]).join(" ")

    # "`reset!` does nothing when `TIMEKEEPING_DATABASE_URL` is unset or the database does not exist yet."
    expect(TimekeepingDatabaseReset.reset!("timekeeping", env: { "TIMEKEEPING_DATABASE_URL" => missing })).to be_nil
  end
end

# frozen_string_literal: true

require "rails_helper"
require "open3"
require "pg"

RSpec.describe "Timekeeping owner state harness" do
  # Written out by hand rather than read from TimekeepingOwnerState::STATES, so
  # a wrong value in STATES fails these examples instead of being compared with itself.
  # "`legacy` is owner monolith, `monolith_store` legacy, generation 1. `timekeeping` is owner timekeeping,
  # generation 2, `legacy_retired_at` set. `rollback` is owner monolith, store prepared, generation 3."
  # The timekeeping store (legacy, the column default) and rollback keeping legacy_retired_at set are the
  # choices the change discloses.
  let(:expected_owner_states) do
    {
      "legacy" => { owner: "monolith", monolith_store: "legacy", generation: 1, retired: false },
      "timekeeping" => { owner: "timekeeping", monolith_store: "legacy", generation: 2, retired: true },
      "rollback" => { owner: "monolith", monolith_store: "prepared", generation: 3, retired: true }
    }
  end

  # "Use the column default (generation 1) when no state is set and for legacy, generation 2 for timekeeping,
  # and null (fenced, because the monolith owns) for rollback."
  let(:expected_admission_generations) { { nil => 1, "legacy" => 1, "timekeeping" => 2, "rollback" => nil } }

  owner_state_names = %w[legacy timekeeping rollback]

  describe "TestDatabaseGuard.require_test_database!" do
    # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI
    # database in .github/workflows/validations.yml does."
    [
      nil, "", "timekeeping_test_copy", "timekeeping_testing", "timekeeping_TEST", "timekeeping_test ",
      "timekeeping_demo", "timekeeping_test_backup"
    ].each do |name|
      it "refuses #{name.inspect}" do
        expect { TestDatabaseGuard.require_test_database!(name) }
          .to raise_error(TestDatabaseGuard::NotATestDatabase)
      end
    end

    %w[timekeeping_test timekeeping_live_test timekeeping_runtime_test].each do |name|
      it "accepts #{name.inspect}" do
        expect(TestDatabaseGuard.require_test_database!(name)).to be_nil
      end
    end
  end

  describe "TimekeepingOwnerState" do
    def ownership_snapshot
      row = TimekeepingOwnership.current
      {
        owner: row.owner, monolith_store: row.monolith_store, generation: row.generation,
        retired: !row.legacy_retired_at.nil?, handoff_step: row.handoff_step,
        final_outbox_position: row.final_outbox_position, legacy_retired_at: row.legacy_retired_at
      }
    end

    def update_ownership(**columns)
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(columns)
    end

    describe ".selected" do
      # "`TimekeepingOwnerState.selected(env)` returns nil only when the key is absent. Any value other than exactly
      # `legacy`, `timekeeping` or `rollback` raises `ArgumentError` and names all three. That includes an empty
      # string, mixed case and surrounding whitespace."
      it "returns nil when TIMEKEEPING_OWNER_STATE is absent" do
        expect(TimekeepingOwnerState.selected({})).to be_nil
      end

      owner_state_names.each do |name|
        it "returns #{name.inspect} for exactly #{name.inspect}" do
          expect(TimekeepingOwnerState.selected({ "TIMEKEEPING_OWNER_STATE" => name })).to eq(name)
        end
      end

      ["", "ROLLBACK", "rollback ", " legacy", "Timekeeping", "bogus"].each do |value|
        it "refuses #{value.inspect} and names the three states" do
          expect { TimekeepingOwnerState.selected({ "TIMEKEEPING_OWNER_STATE" => value }) }
            .to raise_error(ArgumentError) { |error|
              expect(error.message).to include("legacy", "timekeeping", "rollback")
            }
        end
      end
    end

    describe ".fetch" do
      owner_state_names.each do |name|
        it "gives #{name.inspect} its admission generation in a frozen row" do
          state = TimekeepingOwnerState.fetch(name)

          expect(state[:admission_generation]).to eq(expected_admission_generations.fetch(name))
          expect(state).to be_frozen
        end
      end

      it "keeps STATES frozen and refuses an unknown name, naming the three states" do
        expect(TimekeepingOwnerState::STATES).to be_frozen
        expect { TimekeepingOwnerState.fetch("bogus") }.to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/m)
      end
    end

    describe ".apply!" do
      owner_state_names.each do |name|
        it "writes exactly the #{name.inspect} columns over a mid-handoff row, and repeating it changes nothing" do
          TimekeepingOwnership.ensure_initial!
          update_ownership(handoff_step: "freeze", generation: 9, final_outbox_position: 5,
                           owner: "timekeeping", monolith_store: "prepared", legacy_retired_at: nil)

          TimekeepingOwnerState.apply!(name)
          first = ownership_snapshot

          expect(first.except(:legacy_retired_at))
            .to eq(expected_owner_states.fetch(name).merge(handoff_step: nil, final_outbox_position: nil))

          TimekeepingOwnerState.apply!(name)

          expect(TimekeepingOwnership.count).to eq(1)
          expect(ownership_snapshot).to eq(first)
        end
      end

      # "When the row is missing, it creates it first with `ensure_initial!`."
      it "creates the ownership row when it is missing" do
        TimekeepingOwnership.delete_all

        TimekeepingOwnerState.apply!("rollback")

        expect(TimekeepingOwnership.count).to eq(1)
        expect(ownership_snapshot.slice(:owner, :monolith_store, :generation, :retired))
          .to eq(expected_owner_states.fetch("rollback"))
      end

      # "`TimekeepingOwnerState.apply!(state_name)` writes the row and raises `ArgumentError` on an unknown name."
      ["bogus", "", "ROLLBACK", nil].each do |name|
        it "refuses #{name.inspect}, names the three states and leaves the row unchanged" do
          TimekeepingOwnership.ensure_initial!
          update_ownership(handoff_step: "freeze", generation: 9)
          before = TimekeepingOwnership.current.attributes

          expect { TimekeepingOwnerState.apply!(name) }
            .to raise_error(ArgumentError, /legacy.*timekeeping.*rollback/m)

          expect(TimekeepingOwnership.current.attributes).to eq(before)
        end
      end
    end

    describe "#expect_owner_state!" do
      owner_state_names.each do |name|
        it "passes on the applied #{name.inspect} state" do
          TimekeepingOwnerState.apply!(name)

          expect { expect_owner_state!(name) }.not_to raise_error
        end
      end

      # "It also compares owner, monolith_store, generation and whether legacy_retired_at is set, because
      # `EntryOwner.for` cannot tell generations apart."
      it "fails on rollback when only the generation differs, which EntryOwner.for cannot see" do
        TimekeepingOwnerState.apply!("rollback")
        update_ownership(generation: 4)

        expect(Timekeeping::EntryOwner.for(TimekeepingOwnership.current)).to eq(:prepared)
        expect { expect_owner_state!("rollback") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      end

      it "fails on timekeeping when legacy_retired_at is cleared" do
        TimekeepingOwnerState.apply!("timekeeping")
        update_ownership(legacy_retired_at: nil)

        expect { expect_owner_state!("timekeeping") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      end
    end
  end

  describe "TimekeepingDatabaseReset.reset!" do
    reset_states = [nil, *owner_state_names]

    context "without a reachable database" do
      before do
        allow(PG).to receive(:connect).and_call_original
        allow(PG::Connection).to receive(:new).and_call_original
      end

      guard_user = "owner_state_guard_user"
      guard_password = "owner-state-guard-secret"
      guard_host = "db.invalid"
      conninfo_forms = {
        "URL" => ->(name) { "postgres://#{guard_user}:#{guard_password}@#{guard_host}:5432/#{name}" },
        "keyword" => lambda { |name|
          "host=#{guard_host} port=5432 user=#{guard_user} password=#{guard_password} dbname=#{name}"
        }
      }

      # "So `reset!` refuses unless the database name in `TIMEKEEPING_DATABASE_URL` ends in `_test`, as every CI
      # database in .github/workflows/validations.yml does. The error names only the database, never the URL."
      conninfo_forms.each do |form, conninfo_for|
        %w[timekeeping_demo timekeeping_test_copy timekeeping_TEST timekeeping_test_backup].each do |name|
          reset_states.each do |state|
            it "refuses #{name} in #{form} form for state #{state.inspect} before connecting, naming only the database" do
              conninfo = conninfo_for.call(name)

              expect { TimekeepingDatabaseReset.reset!(state, env: { "TIMEKEEPING_DATABASE_URL" => conninfo }) }
                .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
                  expect(error.message).to include(name)
                  expect(error.message).not_to include(guard_password)
                  expect(error.message).not_to include(guard_user)
                  expect(error.message).not_to include(guard_host)
                  expect(error.message).not_to include(conninfo)
                }
              expect(PG).not_to have_received(:connect)
              expect(PG::Connection).not_to have_received(:new)
            end
          end
        end
      end

      # "`reset!` does nothing when `TIMEKEEPING_DATABASE_URL` is unset or the database does not exist yet."
      reset_states.each do |state|
        it "does nothing for state #{state.inspect} when TIMEKEEPING_DATABASE_URL is absent" do
          expect(TimekeepingDatabaseReset.reset!(state, env: {})).to be_nil
          expect(PG).not_to have_received(:connect)
          expect(PG::Connection).not_to have_received(:new)
        end
      end

      it "refuses an unknown state before reading TIMEKEEPING_DATABASE_URL" do
        expect do
          TimekeepingDatabaseReset.reset!("bogus", env: { "TIMEKEEPING_DATABASE_URL" => "dbname=timekeeping_test" })
        end.to raise_error(ArgumentError)
        expect(PG).not_to have_received(:connect)
        expect(PG::Connection).not_to have_received(:new)
      end

      it "raises, naming only the database, when a _test database cannot be reached" do
        password = "unreachable-secret-7d1e"
        conninfo = "host=127.0.0.1 port=1 user=harness_user password=#{password} dbname=timekeeping_unreachable_test"

        expect { TimekeepingDatabaseReset.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => conninfo }) }
          .to raise_error(PG::ConnectionBad) { |error|
            expect(error.message).to include("timekeeping_unreachable_test")
            expect(error.message).not_to include(password)
            expect(error.message).not_to include("127.0.0.1")
            expect(error.cause).to be_nil
          }
      end
    end

    context "on the live Timekeeping test database" do
      before do
        skip "set TIMEKEEPING_LIVE=1 to use the Timekeeping test database" unless ENV["TIMEKEEPING_LIVE"] == "1"
      end

      let(:live_url) { ENV.fetch("TIMEKEEPING_DATABASE_URL") }

      # The parsed connection options of TIMEKEEPING_DATABASE_URL, after checking it names a _test database.
      let(:live_options) do
        options = PG::Connection.conninfo_parse(live_url).filter_map do |option|
          [option[:keyword], option[:val]] if option[:val]
        end.to_h
        TestDatabaseGuard.require_test_database!(options["dbname"])
        options
      end

      def keyword_conninfo(options)
        options.map { |key, value| "#{key}='#{value.gsub(/['\\]/) { |char| "\\#{char}" }}'" }.join(" ")
      end

      it "empties every table but schema_migrations and ar_internal_metadata and leaves one admission row " \
         "at each state's generation, the same after a repeated reset" do
        live_options # refuses a URL that does not name a _test database before db:prepare touches it
        output, status = Bundler.with_unbundled_env do
          Open3.capture2e({ "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Rails.root.join("timekeeping/Gemfile").to_s,
                            "TIMEKEEPING_DATABASE_URL" => live_url, "DATABASE_URL" => nil },
                          "bundle", "exec", "rails", "db:prepare", chdir: Rails.root.join("timekeeping").to_s)
        end
        raise "db:prepare failed:\n#{output}" unless status.success?

        connection = PG.connect(live_url)
        migrations = connection.exec("SELECT count(*) FROM schema_migrations").getvalue(0, 0).to_i
        metadata = connection.exec("SELECT key, value FROM ar_internal_metadata ORDER BY key").to_a
        expect(metadata).not_to be_empty
        connection.exec("CREATE TABLE IF NOT EXISTS owner_state_reset_probe_rows (id integer)")

        expected_admission_generations.each do |state, generation|
          connection.exec("INSERT INTO owner_state_reset_probe_rows (id) VALUES (1)")
          connection.exec("DELETE FROM admission")
          connection.exec("INSERT INTO admission (id, generation) VALUES (1, 7)")

          2.times do |run|
            label = "state #{state.inspect}, reset #{run + 1}"
            expect(TimekeepingDatabaseReset.reset!(state, env: { "TIMEKEEPING_DATABASE_URL" => live_url })).to be_nil

            # "`reset!` deletes every table except ar_internal_metadata and schema_migrations."
            expect(connection.exec("SELECT count(*) FROM owner_state_reset_probe_rows").getvalue(0, 0).to_i)
              .to eq(0), label
            expect(connection.exec("SELECT count(*) FROM schema_migrations").getvalue(0, 0).to_i)
              .to eq(migrations), label
            expect(connection.exec("SELECT key, value FROM ar_internal_metadata ORDER BY key").to_a)
              .to eq(metadata), label
            expect(connection.exec("SELECT id, generation FROM admission").to_a)
              .to eq([{ "id" => "1", "generation" => generation&.to_s }]), label
          end
        end
      ensure
        connection&.exec("DROP TABLE IF EXISTS owner_state_reset_probe_rows")
        connection&.close
      end

      # "`reset!` refuses a database whose name does not end in `_test` and leaves its rows in place."
      it "refuses a real non-test database and leaves its rows in place" do
        # A unique name, so this example never drops a database it did not create.
        scratch_name = "timekeeping_owner_state_guard_scratch_#{SecureRandom.hex(6)}"
        admin = PG.connect(live_url)
        admin.exec("CREATE DATABASE #{admin.quote_ident(scratch_name)}")
        scratch_created = true
        scratch_options = live_options.merge("dbname" => scratch_name)
        scratch = PG.connect(scratch_options)
        scratch.exec("CREATE TABLE kept_rows (id integer)")
        scratch.exec("INSERT INTO kept_rows (id) VALUES (1)")

        expect do
          TimekeepingDatabaseReset.reset!("legacy", env: { "TIMEKEEPING_DATABASE_URL" => keyword_conninfo(scratch_options) })
        end.to raise_error(TestDatabaseGuard::NotATestDatabase, /#{scratch_name}/o)
        expect(scratch.exec("SELECT count(*) FROM kept_rows").getvalue(0, 0).to_i).to eq(1)
      ensure
        scratch&.close
        admin.exec("DROP DATABASE #{admin.quote_ident(scratch_name)}") if scratch_created
        admin&.close
      end

      # "`reset!` does nothing when `TIMEKEEPING_DATABASE_URL` is unset or the database does not exist yet."
      it "does nothing when the named _test database does not exist yet" do
        missing = keyword_conninfo(live_options.merge("dbname" => "timekeeping_owner_state_never_created_test"))

        expect(TimekeepingDatabaseReset.reset!("timekeeping", env: { "TIMEKEEPING_DATABASE_URL" => missing })).to be_nil
      end
    end
  end

  describe "probe runs", :without_transaction do
    def run_probe(fixture, owner_state)
      probe = Rails.root.join("spec/fixtures/timekeeping_harness", fixture).to_s
      stdout, stderr, status = Open3.capture3({ "TIMEKEEPING_OWNER_STATE" => owner_state },
                                              "bundle", "exec", "rspec", probe, chdir: Rails.root.to_s)
      ["#{stdout}\n#{stderr}", status]
    end

    it "keeps the probe fixtures out of a normal suite run" do
      %w[owner_state_probe.rb unset_owner_state_probe.rb].each do |fixture|
        probe = Rails.root.join("spec/fixtures/timekeeping_harness", fixture)
        expect(probe).to exist
        expect(probe.basename.to_s).not_to end_with("_spec.rb")
      end
    end

    # "`TIMEKEEPING_OWNER_STATE` selects the legacy, timekeeping or rollback ownership state, an unknown value fails
    # loudly, and the selected state survives every cleaner reset"
    owner_state_names.each do |state|
      it "with TIMEKEEPING_OWNER_STATE=#{state} an example after a committed_data example sees the #{state} row" do
        output, status = run_probe("owner_state_probe.rb", state)

        expect(status).to be_success, output
        expect(output).to include("2 examples, 0 failures")
      end
    end

    # "An unknown `TIMEKEEPING_OWNER_STATE` raises at load and names the three values."
    it "with TIMEKEEPING_OWNER_STATE=bogus the run fails at load naming the three values" do
      output, status = run_probe("owner_state_probe.rb", "bogus")

      expect(status).not_to be_success
      expect(output.lines.find { |line| line.include?("ArgumentError") }).not_to be_nil
      expect(output).to match(/legacy.*timekeeping.*rollback/m)
      expect(output).to include("error occurred while loading").or include("errors occurred outside of examples")
    end

    # "An unset value leaves the suite unchanged."
    it "with TIMEKEEPING_OWNER_STATE unset no hook rewrites the ownership row" do
      output, status = run_probe("unset_owner_state_probe.rb", nil)

      expect(status).to be_success, output
      expect(output).to include("1 example, 0 failures")
    end
  end
end

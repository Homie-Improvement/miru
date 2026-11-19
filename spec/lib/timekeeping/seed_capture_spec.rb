# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::SeedCapture do
  context "more tests 2", :two_tenant_seed, :seeded_without_transaction do
    def seed_capture_spec_connection
      ActiveRecord::Base.connection
    end

    def seed_capture_spec_tables
      seed_capture_spec_connection.tables - %w[ar_internal_metadata schema_migrations]
    end

    # Rows are sorted by their own text, not by a primary key, so tables with no
    # key (users_roles, reservations) and duplicate rows are compared too.
    def seed_capture_spec_digests
      seed_capture_spec_tables.sort.to_h do |table|
        quoted = seed_capture_spec_connection.quote_table_name(table)
        row = seed_capture_spec_connection.select_rows(
          "SELECT count(*), md5(coalesce(string_agg(t::text, E'\\n' ORDER BY t::text), '')) FROM #{quoted} t"
        ).first
        [table, row]
      end
    end

    # Read from each sequence itself: pg_sequences has no is_called column and
    # shows NULL last_value for a sequence that never supplied a value.
    def seed_capture_spec_sequences
      names = seed_capture_spec_connection.select_values(<<~SQL)
        SELECT c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S' AND n.nspname = current_schema()
        ORDER BY c.relname
      SQL
      names.to_h do |name|
        quoted = seed_capture_spec_connection.quote_table_name(name)
        [name, seed_capture_spec_connection.select_rows("SELECT last_value, is_called FROM #{quoted}").first]
      end
    end

    it "restores every seeded table's rows, key-less tables included, and every sequence's last_value and is_called exactly as the seed load left them" do
      digests_after_seed = seed_capture_spec_digests
      sequences_after_seed = seed_capture_spec_sequences
      expect(digests_after_seed.fetch("users_roles").first.to_i).to be_positive

      capture = described_class.take(connection: seed_capture_spec_connection, tables: seed_capture_spec_tables)

      TestDatabaseCleanup.before_reset!
      DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
      expect(User.count).to eq(0)

      # "Reloading the two-tenant seed for a handoff example group takes well under a minute, either through bulk inserts in db/seeds.rb or by restoring a captured snapshot, and gives the same ids and sequence values as before."
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capture.restore!(connection: seed_capture_spec_connection)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(seed_capture_spec_digests).to eq(digests_after_seed)
      expect(seed_capture_spec_sequences).to eq(sequences_after_seed)
      expect(elapsed).to be < 20
    end
  end

  context "more tests 3", :without_transaction do
    def seed_capture_spec_connection
      ActiveRecord::Base.connection
    end

    def seed_capture_spec_tables
      seed_capture_spec_connection.tables - %w[ar_internal_metadata schema_migrations]
    end

    # Rows are compared as text sorted by that text, so tables with no primary
    # key (reservations, users_roles) and duplicate rows are compared too.
    def seed_capture_spec_table_digests
      seed_capture_spec_tables.sort.to_h do |table|
        quoted = seed_capture_spec_connection.quote_table_name(table)
        row = seed_capture_spec_connection.select_one(<<~SQL)
          SELECT count(*) AS row_count,
                 md5(coalesce(string_agg(t::text, E'\\n' ORDER BY t::text), '')) AS digest
          FROM #{quoted} t
        SQL
        [table, [row["row_count"].to_i, row["digest"]]]
      end
    end

    # Read from each sequence itself: pg_sequences has no is_called column and
    # shows NULL for a sequence that never supplied a value.
    def seed_capture_spec_sequence_states
      names = seed_capture_spec_connection.select_values(<<~SQL)
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S' AND n.nspname = current_schema()
      SQL
      names.sort.to_h do |name|
        row = seed_capture_spec_connection.select_one(
          "SELECT last_value, is_called FROM #{seed_capture_spec_connection.quote_table_name(name)}"
        )
        [name, [row["last_value"].to_i, row["is_called"]]]
      end
    end

    def seed_capture_spec_next_ids
      %w[users timekeeping_ownership].to_h do |table|
        sequence = seed_capture_spec_connection.select_value(
          "SELECT pg_get_serial_sequence(#{seed_capture_spec_connection.quote(table)}, 'id')"
        )
        [table, seed_capture_spec_connection.select_value("SELECT nextval(#{seed_capture_spec_connection.quote(sequence)})").to_i]
      end
    end

    it "restores the seeded rows of every table, key-less ones included, and every sequence's state, well under a minute" do
      # The :without_transaction hook leaves the ownership row behind, and the
      # seed load refuses any occupied table, so empty everything first as the
      # two-tenant seed context does.
      DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
      Timekeeping::SeedDispositionRecorder.load_fresh_seed!(as_of: TestDatabaseCleanup.seed_as_of)
      loaded_digests = seed_capture_spec_table_digests
      loaded_sequences = seed_capture_spec_sequence_states
      expect(loaded_digests.fetch("users_roles").first).to be_positive
      expect(loaded_digests.fetch("rails_event_viewer_entries").first).to be_positive

      capture = described_class.take(connection: seed_capture_spec_connection, tables: seed_capture_spec_tables)
      loaded_next_ids = seed_capture_spec_next_ids

      DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capture.restore!(connection: seed_capture_spec_connection)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      # "Reloading the two-tenant seed for a handoff example group takes well under a minute, either through bulk inserts in db/seeds.rb or by restoring a captured snapshot, and gives the same ids and sequence values as before."
      expect(seed_capture_spec_table_digests).to eq(loaded_digests)
      expect(seed_capture_spec_sequence_states).to eq(loaded_sequences)
      expect(seed_capture_spec_next_ids).to eq(loaded_next_ids)
      expect(elapsed).to be < 20
    end
  end

  context "when a seed capture restore cannot complete", :without_transaction do
    def seed_capture_failure_spec_take
      described_class.take(
        connection: ActiveRecord::Base.connection,
        tables: ActiveRecord::Base.connection.tables - %w[ar_internal_metadata schema_migrations]
      )
    end

    def seed_capture_failure_spec_truncate
      DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata schema_migrations)
    end

    it "brings back an attachment whose file is still on disk" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("receipt bytes"), filename: "receipt.txt")
      capture = seed_capture_failure_spec_take
      seed_capture_failure_spec_truncate

      capture.restore!(connection: ActiveRecord::Base.connection)

      expect(ActiveStorage::Blob.find(blob.id).download).to eq("receipt bytes")
    end

    it "raises before writing any row when an attachment file is missing" do
      create(:company, name: "Capture Co")
      capture = seed_capture_failure_spec_take
      missing = described_class::Blob.new(service_name: ActiveStorage::Blob.service.name, key: "seed-capture-missing-key")
      seed_capture_failure_spec_truncate

      expect { capture.with(blobs: [missing]).restore!(connection: ActiveRecord::Base.connection) }
        .to raise_error(described_class::RestoreError, /seed-capture-missing-key/)
      expect(Company.count).to eq(0)
    end

    it "rolls back every row written before a failing table and raises" do
      create(:company, name: "Capture Co")
      capture = seed_capture_failure_spec_take
      broken = described_class::Table.new(name: "users", columns: ["id"], rows: "not-a-number\n")
      seed_capture_failure_spec_truncate

      expect { capture.with(tables: capture.tables + [broken]).restore!(connection: ActiveRecord::Base.connection) }
        .to raise_error(described_class::RestoreError)
      expect(Company.count).to eq(0)
      expect(User.count).to eq(0)
    end
  end
end

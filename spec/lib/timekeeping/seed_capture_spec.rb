# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::SeedCapture do
  context "after a real seed load", :without_transaction do
    def seed_capture_spec_connection
      ActiveRecord::Base.connection
    end

    def seed_capture_spec_tables
      seed_capture_spec_connection.tables - %w[ar_internal_metadata schema_migrations]
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
      # two-tenant seed context does. The process store is used, as that
      # context does, so this runs db/seeds.rb only when no earlier group has.
      TestDatabaseCleanup.before_reset!
      DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
      Timekeeping::SeedDispositionRecorder.load_fresh_seed!(
        as_of: TestDatabaseCleanup.seed_as_of, captures: TestDatabaseCleanup.seed_captures
      )
      loaded_digests = SeedStateComparison.table_digests
      loaded_sequences = SeedStateComparison.sequence_states
      expect(loaded_digests.fetch("users_roles").first).to be_positive
      expect(loaded_digests.fetch("rails_event_viewer_entries").first).to be_positive

      capture = described_class.take(connection: seed_capture_spec_connection, tables: seed_capture_spec_tables)
      loaded_next_ids = seed_capture_spec_next_ids

      DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
      expect(User.count).to eq(0)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capture.restore!(connection: seed_capture_spec_connection)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      # "Reloading the two-tenant seed for a handoff example group takes well under a minute, either through bulk inserts in db/seeds.rb or by restoring a captured snapshot, and gives the same ids and sequence values as before."
      expect(SeedStateComparison.table_digests).to eq(loaded_digests)
      expect(SeedStateComparison.sequence_states).to eq(loaded_sequences)
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

# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
require Rails.root.join("db/migrate/20261020120000_drop_timesheet_entry_foreign_keys")

# Runs the migration's up and down inside the example's transaction, so every
# key it drops or restores is rolled back after the example.
RSpec.describe DropTimesheetEntryForeignKeysForCutover do
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutover_keys) do
    [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
  end
  let(:link_key) { cutover_keys[0] }
  let(:line_item_key) { cutover_keys[1] }
  let(:agent_key) { cutover_keys[2] }

  def run_cutover_migration(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def present_cutover_keys
    cutover_keys.select do |key|
      connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])
    end
  end

  def add_cutover_key(key, validate: true)
    connection.add_foreign_key key[:from_table], key[:to_table], column: key[:column], validate:, if_not_exists: true
  end

  # The loaded schema no longer declares the keys; removing them anyway keeps
  # each example independent of that, so a down that adds nothing cannot pass.
  def remove_cutover_keys
    cutover_keys.each do |key|
      connection.remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
  end

  # One entry per constraint on the key's column, so a key added twice shows up.
  def cutover_key_validations(key)
    connection.select_values(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE contype = 'f'
        AND conrelid = #{connection.quote(key[:from_table].to_s)}::regclass
        AND confrelid = #{connection.quote(key[:to_table].to_s)}::regclass
        AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
          WHERE attrelid = #{connection.quote(key[:from_table].to_s)}::regclass
            AND attname = #{connection.quote(key[:column].to_s)})]::smallint[]
    SQL
  end

  def expect_projects_and_users_keys_kept
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end

  describe "up" do
    it "removes all three cutover keys and keeps the projects and users keys, and a repeated up changes nothing" do
      # Start from a database that holds the keys, so an up that removes nothing cannot pass.
      cutover_keys.each { |key| add_cutover_key(key) }
      expect(present_cutover_keys).to eq(cutover_keys)

      run_cutover_migration(:up)

      expect(present_cutover_keys).to eq([])
      expect_projects_and_users_keys_kept

      expect { run_cutover_migration(:up) }.not_to raise_error
      expect(present_cutover_keys).to eq([])
      expect_projects_and_users_keys_kept
    end

    # The migration runs outside a transaction, so a failed run can leave some keys gone and the version unrecorded.
    it "finishes the drop, and runs again safely, when an earlier run stopped after removing only the first key" do
      remove_cutover_keys
      add_cutover_key(line_item_key)
      add_cutover_key(agent_key)

      expect { run_cutover_migration(:up) }.not_to raise_error
      expect { run_cutover_migration(:up) }.not_to raise_error

      expect(present_cutover_keys).to eq([])
      expect_projects_and_users_keys_kept
    end

    it "removes the remaining key when an earlier run stopped with only the agents key left" do
      remove_cutover_keys
      add_cutover_key(agent_key)

      expect { run_cutover_migration(:up) }.not_to raise_error

      expect(present_cutover_keys).to eq([])
      expect_projects_and_users_keys_kept
    end
  end

  describe "down" do
    it "restores all three cutover keys, each validated, on a database that lost them" do
      remove_cutover_keys

      run_cutover_migration(:down)

      expect(present_cutover_keys).to eq(cutover_keys)
      cutover_keys.each do |key|
        expect(cutover_key_validations(key)).to eq([true]), "expected #{key[:from_table]}.#{key[:column]} validated"
      end
    end

    # An interrupted rollback can leave one key added but not yet validated.
    it "ends with each key present once and validated when an interrupted rollback left one key unvalidated" do
      [link_key, agent_key].each do |unvalidated_key|
        remove_cutover_keys
        add_cutover_key(unvalidated_key, validate: false)
        expect(cutover_key_validations(unvalidated_key)).to eq([false])

        run_cutover_migration(:down)

        cutover_keys.each do |key|
          expect(cutover_key_validations(key)).to eq([true]), "expected one validated key on #{key[:from_table]}.#{key[:column]}"
        end
      end
    end

    it "refuses, adds no key and keeps every dangling row when an entry, a line item and a link point at missing records" do
      remove_cutover_keys
      entry = create(:timesheet_entry)
      line_item = create(:invoice_line_item)
      link = create(:invoice_line_item_time_entry)
      missing_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000
      missing_agent_id = Agent.maximum(:id).to_i + 1_000
      connection.execute("UPDATE timesheet_entries SET agent_id = #{missing_agent_id} WHERE id = #{entry.id}")
      connection.execute("UPDATE invoice_line_items SET timesheet_entry_id = #{missing_entry_id} WHERE id = #{line_item.id}")
      connection.execute("UPDATE invoice_line_item_time_entries SET timesheet_entry_id = #{missing_entry_id} WHERE id = #{link.id}")
      entry_row_before = connection.select_one("SELECT * FROM timesheet_entries WHERE id = #{entry.id}")
      counts_before = %w[timesheet_entries invoice_line_items invoice_line_item_time_entries]
        .index_with { |table| connection.select_value("SELECT count(*) FROM #{table}").to_i }

      expect { run_cutover_migration(:down) }
        .to raise_error(described_class::DanglingReferencesError) { |error|
          expect(error.message).to include("invoice_line_item_time_entries.timesheet_entry_id: 1")
          expect(error.message).to include("invoice_line_items.timesheet_entry_id: 1")
          expect(error.message).to include("timesheet_entries.agent_id: 1")
        }

      expect(present_cutover_keys).to eq([])
      expect(connection.select_one("SELECT * FROM timesheet_entries WHERE id = #{entry.id}")).to eq(entry_row_before)
      expect(line_item.reload.timesheet_entry_id).to eq(missing_entry_id)
      expect(link.reload.timesheet_entry_id).to eq(missing_entry_id)
      counts_after = counts_before.keys.index_with { |table| connection.select_value("SELECT count(*) FROM #{table}").to_i }
      expect(counts_after).to eq(counts_before)
    end

    it "names each billing column and its count when a link row and two line items point at missing entries" do
      remove_cutover_keys
      link = create(:invoice_line_item_time_entry)
      line_items = create_list(:invoice_line_item, 2)
      missing_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000
      connection.execute("UPDATE invoice_line_item_time_entries SET timesheet_entry_id = #{missing_entry_id} " \
                         "WHERE id = #{link.id}")
      connection.execute("UPDATE invoice_line_items SET timesheet_entry_id = #{missing_entry_id} " \
                         "WHERE id IN (#{line_items.map(&:id).join(', ')})")

      expect { run_cutover_migration(:down) }
        .to raise_error(described_class::DanglingReferencesError) { |error|
          expect(error.message).to include("invoice_line_item_time_entries.timesheet_entry_id: 1")
          expect(error.message).to include("invoice_line_items.timesheet_entry_id: 2")
        }

      expect(link.reload.timesheet_entry_id).to eq(missing_entry_id)
      expect(line_items.map { |item| item.reload.timesheet_entry_id }).to eq([missing_entry_id, missing_entry_id])
      expect(present_cutover_keys).to eq([])
    end

    # The dangling row sits on the last key in the list, so a check run per key after adding earlier keys would be caught.
    it "refuses before adding any key when an entry names a missing agent, even with one key already restored" do
      remove_cutover_keys
      add_cutover_key(line_item_key)
      entry = create(:timesheet_entry)
      missing_agent_id = Agent.maximum(:id).to_i + 1_000
      connection.execute("UPDATE timesheet_entries SET agent_id = #{missing_agent_id} WHERE id = #{entry.id}")
      entry_count = TimesheetEntry.count

      expect { run_cutover_migration(:down) }
        .to raise_error(described_class::DanglingReferencesError, /timesheet_entries\.agent_id: 1/)

      expect(entry.reload.agent_id).to eq(missing_agent_id)
      expect(TimesheetEntry.count).to eq(entry_count)
      expect(present_cutover_keys).to eq([line_item_key])
    end
  end

  # The test database is built from db/schema.rb, so this fails on a schema that still declares the keys.
  it "the loaded schema declares none of the three cutover keys and keeps the projects and users keys" do
    expect(described_class::DROPPED_KEYS).to match_array(cutover_keys)
    expect(present_cutover_keys).to eq([])
    expect_projects_and_users_keys_kept
    expect(ActiveRecord::Base.connection_pool.migration_context.current_version).to be >= 20261121120000

    schema = File.read(Rails.root.join("db/schema.rb"))
    expect(schema).not_to include('add_foreign_key "invoice_line_item_time_entries", "timesheet_entries"')
    expect(schema).not_to include('add_foreign_key "invoice_line_items", "timesheet_entries"')
    expect(schema).not_to include('add_foreign_key "timesheet_entries", "agents"')
    expect(schema).to include('add_foreign_key "timesheet_entries", "projects"')
    expect(schema).to include('add_foreign_key "timesheet_entries", "users"')
    schema_version = schema[/define\(version: ([\d_]+)\)/, 1].delete("_").to_i
    expect(schema_version).to be >= 20261121120000
  end

  # Each recorded migration stays a fixed snapshot: this one holds its own key list and check.
  it "carries its own key list without loading the older drop migration, whose up stays a no-op that keeps the keys" do
    source = Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover.rb").read
    expect(source).not_to match(/DropTimesheetEntryForeignKeys(?!ForCutover)/)
    expect(source).not_to include("20261020120000")
    expect(source).to include("disable_ddl_transaction!")
    expect(source).to include("DROPPED_KEYS")
    expect(source).to include("if_exists: true")
    expect(described_class::DROPPED_KEYS).not_to equal(DropTimesheetEntryForeignKeys::DROPPED_KEYS)

    cutover_keys.each { |key| add_cutover_key(key) }

    ActiveRecord::Migration.suppress_messages { DropTimesheetEntryForeignKeys.new.migrate(:up) }

    expect(present_cutover_keys).to eq(cutover_keys)
  end

  it "the older drop migration spec no longer pins the three keys as present in the loaded schema" do
    older_spec = File.read(Rails.root.join("spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb"))

    expect(older_spec).not_to include("expect(restored_dropped_keys).to eq(described_class::DROPPED_KEYS)")
    expect(older_spec).to include("expect(described_class::DROPPED_KEYS).to match_array(expected)")
  end
end

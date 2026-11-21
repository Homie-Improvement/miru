require "rails_helper"
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")

RSpec.describe DropTimesheetEntryForeignKeysForCutover do
  context "more tests 10" do
  # "A new migration drops `invoice_line_item_time_entries → timesheet_entries`, `invoice_line_items → timesheet_entries` and `timesheet_entries → agents` with `if_exists: true`, and the keys to `projects` and `users` stay"
  it "up removes all three cutover keys and keeps the projects and users keys, and a repeated up changes nothing" do
    connection = ActiveRecord::Base.connection
    cutover_keys = [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
    # Start from a database that holds the keys, so an up that removes nothing cannot pass.
    cutover_keys.each do |key|
      connection.add_foreign_key key[:from_table], key[:to_table], column: key[:column], if_not_exists: true
    end
    present = -> { cutover_keys.select { |key| connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column]) } }
    expect(present.call).to eq(cutover_keys)

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

    expect(present.call).to eq([])
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) } }.not_to raise_error
    expect(present.call).to eq([])
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end
  end

  context "more tests 11" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "`up` removes each of the three keys with `remove_foreign_key from_table, to_table, column:, if_exists: true`."
  # The migration runs outside a transaction, so a failed run can leave some keys gone and the version unrecorded.
  it "up finishes the drop when an earlier run stopped after removing only the first key" do
    connection = ActiveRecord::Base.connection
    connection.remove_foreign_key :invoice_line_item_time_entries, :timesheet_entries, column: :timesheet_entry_id, if_exists: true
    connection.add_foreign_key :invoice_line_items, :timesheet_entries, column: :timesheet_entry_id, if_not_exists: true
    connection.add_foreign_key :timesheet_entries, :agents, column: :agent_id, if_not_exists: true

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) } }.not_to raise_error

    expect(connection.foreign_key_exists?(:invoice_line_item_time_entries, :timesheet_entries, column: :timesheet_entry_id)).to be(false)
    expect(connection.foreign_key_exists?(:invoice_line_items, :timesheet_entries, column: :timesheet_entry_id)).to be(false)
    expect(connection.foreign_key_exists?(:timesheet_entries, :agents, column: :agent_id)).to be(false)
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end
  end

  context "more tests 12" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "Its rollback restores and validates all three keys, and refuses without changing data when any row points at a missing record"
  it "down restores all three cutover keys validated, including after an interrupted rollback left one unvalidated" do
    connection = ActiveRecord::Base.connection
    cutover_keys = [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
    validated = lambda do |key|
      connection.select_value(<<~SQL.squish)
        SELECT convalidated FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid = #{connection.quote(key[:from_table].to_s)}::regclass
          AND confrelid = #{connection.quote(key[:to_table].to_s)}::regclass
          AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
            WHERE attrelid = #{connection.quote(key[:from_table].to_s)}::regclass
              AND attname = #{connection.quote(key[:column].to_s)})]::smallint[]
      SQL
    end
    # Remove every key first, so a down that adds nothing cannot pass through if_not_exists.
    cutover_keys.each do |key|
      connection.remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
    # An interrupted rollback can leave one key added but not yet validated.
    agent_key = cutover_keys.last
    connection.add_foreign_key agent_key[:from_table], agent_key[:to_table], column: agent_key[:column], validate: false
    expect(validated.call(agent_key)).to be(false)

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) }

    cutover_keys.each do |key|
      expect(connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column]))
        .to be(true), "expected #{key[:from_table]}.#{key[:column]} to be restored"
      expect(validated.call(key)).to be(true), "expected #{key[:from_table]}.#{key[:column]} to be validated"
    end
    expect(connection.foreign_keys(:timesheet_entries).count { |fk| fk.column == "agent_id" }).to eq(1)
  end
  end

  context "more tests 13" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "`down` counts rows whose reference points at a missing row, raises naming each column and count without changing data when any exists, and otherwise adds each key with `validate: false, if_not_exists: true` and then validates it."
  it "down refuses, adds no key and keeps every dangling row when an entry, a line item and a link point at missing records" do
    connection = ActiveRecord::Base.connection
    cutover_keys = [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
    cutover_keys.each do |key|
      connection.remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
    entry = create(:timesheet_entry)
    line_item = create(:invoice_line_item)
    link = create(:invoice_line_item_time_entry)
    missing_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000
    missing_agent_id = Agent.maximum(:id).to_i + 1_000
    connection.execute("UPDATE timesheet_entries SET agent_id = #{missing_agent_id} WHERE id = #{entry.id}")
    connection.execute("UPDATE invoice_line_items SET timesheet_entry_id = #{missing_entry_id} WHERE id = #{line_item.id}")
    connection.execute("UPDATE invoice_line_item_time_entries SET timesheet_entry_id = #{missing_entry_id} WHERE id = #{link.id}")
    counts_before = %w[timesheet_entries invoice_line_items invoice_line_item_time_entries]
      .to_h { |table| [table, connection.select_value("SELECT count(*) FROM #{table}").to_i] }

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) } }
      .to raise_error(described_class::DanglingReferencesError) { |error|
        expect(error.message).to include("invoice_line_item_time_entries.timesheet_entry_id: 1")
        expect(error.message).to include("invoice_line_items.timesheet_entry_id: 1")
        expect(error.message).to include("timesheet_entries.agent_id: 1")
      }

    cutover_keys.each do |key|
      expect(connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])).to be(false)
    end
    expect(entry.reload.agent_id).to eq(missing_agent_id)
    expect(line_item.reload.timesheet_entry_id).to eq(missing_entry_id)
    expect(link.reload.timesheet_entry_id).to eq(missing_entry_id)
    counts_after = counts_before.keys.to_h { |table| [table, connection.select_value("SELECT count(*) FROM #{table}").to_i] }
    expect(counts_after).to eq(counts_before)
  end
  end

  context "more tests 14" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "`db/migrate/20261020120000_drop_timesheet_entry_foreign_keys.rb` is unchanged and `db/schema.rb` is regenerated without the three keys"
  # The test database is built from db/schema.rb, so this fails on a schema that still declares the keys.
  it "the loaded schema declares none of the three cutover keys and keeps the projects and users keys" do
    connection = ActiveRecord::Base.connection

    expect(described_class::DROPPED_KEYS).to match_array([
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ])
    described_class::DROPPED_KEYS.each do |key|
      expect(connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column]))
        .to be(false), "expected the schema not to declare #{key[:from_table]}.#{key[:column]}"
    end
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
    expect(ActiveRecord::Base.connection_pool.migration_context.current_version).to be >= 20261121120000
  end
  end

  context "more tests 15" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
require Rails.root.join("db/migrate/20261020120000_drop_timesheet_entry_foreign_keys")
  # "Never edit or delete `20261020120000` (see docs/solutions/conventions/undo-a-recorded-migration-with-noop-up-and-up-then-down-restore.md)."
  # "Define the key list and the check in this migration rather than loading the older migration class, so each recorded migration stays a fixed snapshot."
  it "leaves the recorded 20261020120000 migration a no-op up that keeps the keys, and holds its own key list without loading that class" do
    connection = ActiveRecord::Base.connection
    expected_keys = [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]

    new_source = Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover.rb").read
    expect(new_source).not_to include("DropTimesheetEntryForeignKeys::")
    expect(new_source).not_to include("20261020120000")
    expect(described_class::DROPPED_KEYS).to match_array(expected_keys)
    expect(described_class::DROPPED_KEYS).not_to equal(DropTimesheetEntryForeignKeys::DROPPED_KEYS)

    expected_keys.each do |key|
      connection.add_foreign_key key[:from_table], key[:to_table], column: key[:column], if_not_exists: true
    end

    ActiveRecord::Migration.suppress_messages { DropTimesheetEntryForeignKeys.new.migrate(:up) }

    expected_keys.each do |key|
      expect(connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column]))
        .to be(true), "expected the recorded migration's up to keep #{key[:from_table]}.#{key[:column]}"
    end
  end
  end

  context "more tests 16" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutover_keys) do
    [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
  end

  # "A new migration drops `invoice_line_item_time_entries → timesheet_entries`, `invoice_line_items →
  # timesheet_entries` and `timesheet_entries → agents` with `if_exists: true`, and the keys to `projects` and
  # `users` stay"
  it "up removes the three cutover keys from a database that holds them and keeps the projects and users keys" do
    # The loaded schema no longer declares the keys, so add them first; otherwise an up that removes nothing passes.
    cutover_keys.each do |key|
      connection.add_foreign_key key[:from_table], key[:to_table], column: key[:column], if_not_exists: true
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

    remaining = cutover_keys.select do |key|
      connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])
    end
    expect(remaining).to eq([])
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end
  end

  context "more tests 17" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutover_keys) do
    [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
  end

  # "`up` removes each of the three keys with `remove_foreign_key from_table, to_table, column:, if_exists: true`."
  # The migration runs outside one transaction, so a stopped run can leave only some keys removed.
  it "up runs again without error after a run that stopped part-way and after a full run" do
    _link_key, line_item_key, agent_key = cutover_keys
    [line_item_key, agent_key].each do |key|
      connection.add_foreign_key key[:from_table], key[:to_table], column: key[:column], if_not_exists: true
    end
    link_key = cutover_keys.first
    connection.remove_foreign_key link_key[:from_table], link_key[:to_table], column: link_key[:column],
                                                                             if_exists: true

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) } }.not_to raise_error
    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) } }.not_to raise_error

    remaining = cutover_keys.select do |key|
      connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])
    end
    expect(remaining).to eq([])
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end
  end

  context "more tests 18" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutover_keys) do
    [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
  end

  def cutover_key_validated?(key)
    connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE contype = 'f'
        AND conrelid = #{connection.quote(key[:from_table].to_s)}::regclass
        AND confrelid = #{connection.quote(key[:to_table].to_s)}::regclass
        AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
          WHERE attrelid = #{connection.quote(key[:from_table].to_s)}::regclass
            AND attname = #{connection.quote(key[:column].to_s)})]::smallint[]
    SQL
  end

  # "Its rollback restores and validates all three keys, and refuses without changing data when any row points at
  # a missing record"
  it "down restores all three cutover keys, each validated, on a database that lost them" do
    # Removed first: a restore that adds with if_not_exists would otherwise pass even if it added nothing.
    cutover_keys.each do |key|
      connection.remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) }

    cutover_keys.each do |key|
      expect(connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column]))
        .to be(true), "expected #{key[:from_table]}.#{key[:column]} to be restored"
      expect(cutover_key_validated?(key)).to be(true), "expected #{key[:from_table]}.#{key[:column]} validated"
    end
  end
  end

  context "more tests 19" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutover_keys) do
    [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
  end

  # "`down` counts rows whose reference points at a missing row, raises naming each column and count without
  # changing data when any exists, and otherwise adds each key with `validate: false, if_not_exists: true` and then
  # validates it."
  it "down refuses, adds no key and keeps the row when an entry names a missing agent" do
    cutover_keys.each do |key|
      connection.remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
    entry = create(:timesheet_entry)
    missing_agent_id = Agent.maximum(:id).to_i + 1_000
    connection.execute("UPDATE timesheet_entries SET agent_id = #{missing_agent_id} WHERE id = #{entry.id}")
    entry_count = TimesheetEntry.count
    row_before = connection.select_one("SELECT * FROM timesheet_entries WHERE id = #{entry.id}")

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) } }
      .to raise_error(described_class::DanglingReferencesError, /timesheet_entries\.agent_id: 1/)

    restored = cutover_keys.select do |key|
      connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])
    end
    expect(restored).to eq([])
    expect(TimesheetEntry.count).to eq(entry_count)
    expect(connection.select_one("SELECT * FROM timesheet_entries WHERE id = #{entry.id}")).to eq(row_before)
  end
  end

  context "more tests 20" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutover_keys) do
    [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
  end

  # "`down` counts rows whose reference points at a missing row, raises naming each column and count without
  # changing data when any exists, and otherwise adds each key with `validate: false, if_not_exists: true` and then
  # validates it."
  it "down names each billing column and its count when a link row and a line item point at missing entries" do
    cutover_keys.each do |key|
      connection.remove_foreign_key key[:from_table], key[:to_table], column: key[:column], if_exists: true
    end
    link = create(:invoice_line_item_time_entry)
    line_items = create_list(:invoice_line_item, 2)
    missing_entry_id = TimesheetEntry.maximum(:id).to_i + 1_000
    connection.execute("UPDATE invoice_line_item_time_entries SET timesheet_entry_id = #{missing_entry_id} " \
                       "WHERE id = #{link.id}")
    connection.execute("UPDATE invoice_line_items SET timesheet_entry_id = #{missing_entry_id} " \
                       "WHERE id IN (#{line_items.map(&:id).join(', ')})")

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) } }
      .to raise_error(described_class::DanglingReferencesError) { |error|
        expect(error.message).to include("invoice_line_item_time_entries.timesheet_entry_id: 1")
        expect(error.message).to include("invoice_line_items.timesheet_entry_id: 2")
      }

    expect(link.reload.timesheet_entry_id).to eq(missing_entry_id)
    expect(line_items.map { |item| item.reload.timesheet_entry_id }).to eq([missing_entry_id, missing_entry_id])
    restored = cutover_keys.select do |key|
      connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])
    end
    expect(restored).to eq([])
  end
  end

  context "more tests 21" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  let(:connection) { ActiveRecord::Base.connection }

  # "`db/migrate/20261020120000_drop_timesheet_entry_foreign_keys.rb` is unchanged and `db/schema.rb` is
  # regenerated without the three keys"
  it "the loaded schema declares none of the three cutover keys and keeps the projects and users keys" do
    expected_keys = [
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ]
    expect(described_class::DROPPED_KEYS).to match_array(expected_keys)

    # The test database is built from db/schema.rb, so this reads what the schema declares.
    declared = expected_keys.select do |key|
      connection.foreign_key_exists?(key[:from_table], key[:to_table], column: key[:column])
    end
    expect(declared).to eq([])
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)

    schema = File.read(Rails.root.join("db/schema.rb"))
    expect(schema).not_to include('add_foreign_key "invoice_line_item_time_entries", "timesheet_entries"')
    expect(schema).not_to include('add_foreign_key "invoice_line_items", "timesheet_entries"')
    expect(schema).not_to include('add_foreign_key "timesheet_entries", "agents"')
    expect(schema).to include('add_foreign_key "timesheet_entries", "projects"')
    expect(schema).to include('add_foreign_key "timesheet_entries", "users"')
    schema_version = schema[/define\(version: ([\d_]+)\)/, 1].delete("_").to_i
    expect(schema_version).to be >= 20261121120000
  end
  end

  context "more tests 22" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "Define the key list and the check in this migration rather than loading the older migration class, so each
  # recorded migration stays a fixed snapshot."
  it "the cutover migration carries its own key list and never loads the older drop migration" do
    source = File.read(Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover.rb"))

    expect(source).not_to match(/DropTimesheetEntryForeignKeys(?!ForCutover)/)
    expect(source).not_to include("20261020120000")
    expect(source).to include("disable_ddl_transaction!")
    expect(source).to include("DROPPED_KEYS")
    expect(source).to include("if_exists: true")
  end
  end

  context "more tests 23" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "In `spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb`, "every key in DROPPED_KEYS is present in the
  # loaded schema" keeps its key-list check and loses its schema-presence assertion, and examples that need a database
  # holding the keys add them first."
  it "the older drop migration spec no longer pins the three keys as present in the loaded schema" do
    older_spec = File.read(Rails.root.join("spec/db/migrations/drop_timesheet_entry_foreign_keys_spec.rb"))

    expect(older_spec).not_to include("expect(restored_dropped_keys).to eq(described_class::DROPPED_KEYS)")
    expect(older_spec).to include("expect(described_class::DROPPED_KEYS).to match_array(expected)")
    expect(described_class::DROPPED_KEYS).to match_array([
      { from_table: :invoice_line_item_time_entries, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :invoice_line_items, to_table: :timesheet_entries, column: :timesheet_entry_id },
      { from_table: :timesheet_entries, to_table: :agents, column: :agent_id }
    ])
  end
  end

  context "more tests 24" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "A new migration drops `invoice_line_item_time_entries → timesheet_entries`, `invoice_line_items → timesheet_entries` and `timesheet_entries → agents` with `if_exists: true`, and the keys to `projects` and `users` stay"
  # The migration runs outside a DDL transaction, so an interrupted up can leave only the agents key behind.
  it "up resumed after a run that stopped part-way removes the remaining key and keeps the projects and users keys" do
    connection = ActiveRecord::Base.connection
    keys = [
      [:invoice_line_item_time_entries, :timesheet_entries, :timesheet_entry_id],
      [:invoice_line_items, :timesheet_entries, :timesheet_entry_id],
      [:timesheet_entries, :agents, :agent_id]
    ]
    keys.each do |from, to, column|
      connection.remove_foreign_key from, to, column:, if_exists: true
    end
    connection.add_foreign_key :timesheet_entries, :agents, column: :agent_id
    connection.validate_foreign_key :timesheet_entries, :agents, column: :agent_id

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) } }.not_to raise_error

    keys.each do |from, to, column|
      expect(connection.foreign_key_exists?(from, to, column:)).to be(false), "expected #{from}.#{column} to lose its key"
    end
    expect(connection.foreign_key_exists?(:timesheet_entries, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:timesheet_entries, :users)).to be(true)
  end
  end

  context "more tests 25" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "Its rollback restores and validates all three keys, and refuses without changing data when any row points at a missing record"
  # An interrupted rollback can leave a key added with validate: false and the others absent.
  it "down resumed after an interrupted rollback left one key unvalidated ends with all three keys present and validated" do
    connection = ActiveRecord::Base.connection
    keys = [
      [:invoice_line_item_time_entries, :timesheet_entries, :timesheet_entry_id],
      [:invoice_line_items, :timesheet_entries, :timesheet_entry_id],
      [:timesheet_entries, :agents, :agent_id]
    ]
    keys.each do |from, to, column|
      connection.remove_foreign_key from, to, column:, if_exists: true
    end
    connection.add_foreign_key :invoice_line_item_time_entries, :timesheet_entries,
      column: :timesheet_entry_id, validate: false

    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) }

    keys.each do |from, to, column|
      validated = connection.select_values(<<~SQL.squish)
        SELECT convalidated FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid = #{connection.quote(from.to_s)}::regclass
          AND confrelid = #{connection.quote(to.to_s)}::regclass
          AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
            WHERE attrelid = #{connection.quote(from.to_s)}::regclass
              AND attname = #{connection.quote(column.to_s)})]::smallint[]
      SQL
      expect(validated).to eq([true]), "expected one validated key on #{from}.#{column}, got #{validated.inspect}"
    end
  end
  end

  context "more tests 26" do
require Rails.root.join("db/migrate/20261121120000_drop_timesheet_entry_foreign_keys_for_cutover")
  # "Its rollback restores and validates all three keys, and refuses without changing data when any row points at a missing record"
  # The dangling row sits on the last key in the list, so a check run per key after adding earlier keys would be caught.
  it "down refuses before adding any key when an entry names a missing agent, even with one key already restored" do
    connection = ActiveRecord::Base.connection
    [
      [:invoice_line_item_time_entries, :timesheet_entries, :timesheet_entry_id],
      [:invoice_line_items, :timesheet_entries, :timesheet_entry_id],
      [:timesheet_entries, :agents, :agent_id]
    ].each do |from, to, column|
      connection.remove_foreign_key from, to, column:, if_exists: true
    end
    connection.add_foreign_key :invoice_line_items, :timesheet_entries, column: :timesheet_entry_id
    connection.validate_foreign_key :invoice_line_items, :timesheet_entries, column: :timesheet_entry_id
    entry = create(:timesheet_entry)
    missing_agent_id = Agent.maximum(:id).to_i + 1_000
    connection.execute("UPDATE timesheet_entries SET agent_id = #{missing_agent_id} WHERE id = #{entry.id}")
    entry_count = TimesheetEntry.count

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) } }
      .to raise_error(described_class::DanglingReferencesError, /timesheet_entries\.agent_id: 1/)

    expect(entry.reload.agent_id).to eq(missing_agent_id)
    expect(TimesheetEntry.count).to eq(entry_count)
    expect(connection.foreign_key_exists?(:invoice_line_item_time_entries, :timesheet_entries,
      column: :timesheet_entry_id)).to be(false)
    expect(connection.foreign_key_exists?(:timesheet_entries, :agents, column: :agent_id)).to be(false)
    expect(connection.foreign_key_exists?(:invoice_line_items, :timesheet_entries,
      column: :timesheet_entry_id)).to be(true)
  end
  end
end

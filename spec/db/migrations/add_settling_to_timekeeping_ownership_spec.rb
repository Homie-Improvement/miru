# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261119120000_add_settling_to_timekeeping_ownership")

# Runs inside the example's transaction, so every schema change rolls back
# after the example.
RSpec.describe AddSettlingToTimekeepingOwnership do
  let(:connection) { ActiveRecord::Base.connection }
  let(:settling_columns) { %w[settling_generation settling_stopped_generation] }

  def migrate_settling_columns(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    TimekeepingOwnership.reset_column_information
  end

  def settling_column_shapes
    connection.columns(:timekeeping_ownership).select { |column| settling_columns.include?(column.name) }
      .to_h { |column| [column.name, [column.sql_type, column.null, column.default]] }
  end

  it "running down removes both settling columns and up adds them back as nullable bigints holding NULL on the existing row" do
    TimekeepingOwnership.ensure_initial!
    applied = settling_columns.index_with { ["bigint", true, nil] }
    expect(settling_column_shapes).to eq(applied)

    migrate_settling_columns(:down)
    expect(settling_column_shapes).to be_empty

    migrate_settling_columns(:up)
    expect(settling_column_shapes).to eq(applied)
    expect(TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(*settling_columns)).to eq([nil, nil])
  ensure
    TimekeepingOwnership.reset_column_information
  end

  # "The new migration runs on a database already migrated through 20261117120000"
  it "is dated after the migrations through 20261118120000, so a database already at that version still runs it" do
    migrations = ActiveRecord::Base.connection_pool.migration_context.migrations
    own = migrations.find { |migration| migration.name == described_class.name }
    earlier = migrations.map(&:version).select { |version| version <= 20261118120000 }

    expect(earlier).to include(20261117120000, 20261118120000)
    expect(own.version).to be > earlier.max
    expect(Rails.root.join("db/schema.rb").read).to include("define(version: #{own.version.to_s.sub(/\A(\d{4})(\d{2})(\d{2})(\d{6})\z/, '\1_\2_\3_\4')})")
  end
end

# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The checkpoint store over the monolith's prepared tables, created by
    # db/migrate/20261025120000_prepare_monolith_for_timekeeping.rb. Those
    # tables carry the checkpoint's own table names. Export and load are
    # TableStore's; this class adds only the outbox position, read from
    # entry_outbox_items, which it never writes.
    class MonolithStore < TableStore
      def initialize(connection:)
        super(connection:, tables: Checkpoint::TABLES.keys.index_with(&:itself))
      end

      def highest_outbox_position
        connection.select_value("SELECT COALESCE(MAX(outbox_position), 0) FROM entry_outbox_items").to_i
      end
    end
  end
end

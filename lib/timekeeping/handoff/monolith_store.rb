# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The checkpoint store over the monolith's prepared tables, created by
    # db/migrate/20261025120000_prepare_monolith_for_timekeeping.rb. Those
    # tables carry the checkpoint's own table names. Export and load are
    # TableStore's; this class adds the outbox position, read from
    # entry_outbox_items, which it never writes.
    #
    # idempotency_records also holds receipts for service callers, which have
    # an actor_name and no actor_id. Timekeeping keeps its service receipts in
    # a table the checkpoint does not carry, so these stay out of it too:
    # export leaves them out, and a load keeps them in place.
    class MonolithStore < TableStore
      RECEIPTS = "idempotency_records"
      RECEIPT_LOCAL_COLUMNS = %w[actor_name].freeze
      USER_RECEIPTS_CONDITION = "actor_type <> 'service'"

      def initialize(connection:)
        super(connection:, tables: Checkpoint::TABLES.keys.index_with(&:itself))
      end

      def highest_outbox_position
        connection.select_value("SELECT COALESCE(MAX(outbox_position), 0) FROM entry_outbox_items").to_i
      end

      private

        def local_columns(table)
          table == RECEIPTS ? RECEIPT_LOCAL_COLUMNS : super
        end

        def checkpoint_rows_condition(table)
          table == RECEIPTS ? USER_RECEIPTS_CONDITION : super
        end

        # Only service receipts remain at this point. Each gets a fresh id
        # from a sequence moved above both the incoming ids and the kept ids,
        # so no kept receipt blocks a checkpoint receipt with the same id. A
        # kept id is read rather than trusted to sit below the sequence,
        # because a row can be inserted with an explicit id. Only the id
        # changes, so the stored answer in body is kept as stored, and no
        # table references receipt ids.
        def before_insert(table, rows)
          return super unless table == RECEIPTS

          highest_kept = connection.select_value("SELECT MAX(id) FROM #{quoted_table(table)}")
          target = [rows.filter_map { |row| row["id"] }.max, highest_kept].compact.max
          return unless target

          advance_sequence(table, target)
          sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table_name(table))}, 'id')")
          connection.execute("UPDATE #{quoted_table(table)} SET id = nextval(#{connection.quote(sequence)})")
        end
    end
  end
end

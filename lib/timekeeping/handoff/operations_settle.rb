# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The settle integration of a non-legacy source (docs/architecture/
    # timekeeping-soa.md section 10.5 step 2): it resolves every invoice
    # operation the outgoing owner registered, and reports done only when no
    # intent is 'pending' and the owner holds no 'prepared' operation.
    #
    # The runner passes the raised generation; the outgoing owner's
    # generation is the one below it, and that is the only one settled or
    # stopped. The owner port carries what differs between the monolith and
    # Timekeeping: opening and stopping the settle step, and counting
    # prepared operations.
    class OperationsSettle
      # Raised when the owner did not open its settle step for the outgoing
      # generation. Redelivering then would only be refused as stale again.
      class NotSettling < StandardError; end

      PENDING_SQL = "SELECT EXISTS (SELECT 1 FROM invoice_operation_intents WHERE state = 'pending')"

      # Delivery builds its request from the row's intent
      # (OutboxDelivery#request_for), not from the generation in the row's
      # payload, so the intent's generation is the one that counts.
      OUTGOING_GENERATION_SQL = <<~SQL.squish
        EXISTS (
          SELECT 1 FROM invoice_operation_intents intents
          WHERE intents.company_id = invoice_operation_outbox_items.company_id
            AND intents.operation_id = invoice_operation_outbox_items.operation_id
            AND (invoice_operation_outbox_items.invoice_id IS NULL
                 OR intents.invoice_id = invoice_operation_outbox_items.invoice_id)
            AND intents.generation = ?
        )
      SQL

      # The outgoing generation, read from the stored row so a restarted
      # runner, which holds nothing in memory, gets the same answer.
      def self.stored_outgoing_generation
        TimekeepingOwnership.current.generation - 1
      end

      # The monolith as outgoing owner: its settle step lives on the
      # timekeeping_ownership row, and its operations in invoice_operations.
      class MonolithPort
        PREPARED_SQL = "SELECT COUNT(*) FROM invoice_operations WHERE state = 'prepared'"

        # connection: nil reads InvoiceOperationsRecord's connection at query
        # time, so a port built at boot leases none on the boot thread.
        def initialize(connection: nil)
          @connection = connection
        end

        # Read back rather than assumed: begin_settling! changes nothing
        # outside a handoff or at a stopped generation.
        def begin_settling(generation:)
          TimekeepingOwnership.begin_settling!(generation:)
          TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).pick(:settling_generation) == generation
        end

        def prepared_operations
          Integer(connection.select_value(PREPARED_SQL))
        end

        def stop_applying(generation:)
          TimekeepingOwnership.stop_applying!(generation:)
          nil
        end

        private

          def connection
            @connection || InvoiceOperationsRecord.connection
          end
      end

      # Timekeeping as outgoing owner, reached through its handoff routes.
      # Its settle call is safe to repeat and is the only read of its
      # prepared count, so prepared_operations calls it again.
      class TimekeepingPort
        def initialize(store:)
          @store = store
        end

        def begin_settling(generation:)
          @store.settle(generation:).settling
        end

        def prepared_operations
          @store.settle(generation: OperationsSettle.stored_outgoing_generation).prepared_operations
        end

        def stop_applying(generation:)
          @store.stop_applying(generation:)
          nil
        end
      end

      # reservations: the adapter commits and aborts are delivered to; the
      # outgoing owner's.
      # connection: where invoice_operation_intents are read; intents are
      # written through InvoiceOperationsRecord's own connection, which nil
      # reads at query time.
      def initialize(owner:, reservations:, connection: nil)
        @owner = owner
        @reservations = reservations
        @connection = connection
      end

      # Every step is safe to repeat: delivery locks each row and skips a
      # delivered one, so no commit or abort is applied twice.
      def settle!(generation:)
        outgoing = generation - 1
        raise NotSettling, "The outgoing owner did not open settling for generation #{outgoing}" unless
          @owner.begin_settling(generation: outgoing)

        rows = undelivered_rows(outgoing)
        # A stale_generation answer marked these before settling was open;
        # the owner now applies them.
        rows.where.not(undeliverable_at: nil).update_all(undeliverable_at: nil)
        rows.where(undeliverable_at: nil).order(:id).pluck(:id).each do |outbox_item_id|
          DeliverInvoiceOperationJob.perform_now(outbox_item_id, reservations: @reservations)
        end
        # Pickup age zero: close_admission waited for every billing write and
        # refuses new ones, so no save is still in flight.
        RecoverInvoiceOperationIntentsJob.perform_now(pickup_age: 0, reservations: @reservations)
        nil
      end

      def settled?
        !pending_intent? && @owner.prepared_operations.zero?
      end

      def stop_applying!
        @owner.stop_applying(generation: self.class.stored_outgoing_generation)
      end

      private

        def undelivered_rows(generation)
          InvoiceOperationOutboxItem.where(delivered_at: nil).where(OUTGOING_GENERATION_SQL, generation)
        end

        def pending_intent?
          ActiveRecord::Type::Boolean.new.cast(connection.select_value(PENDING_SQL))
        end

        def connection
          @connection || InvoiceOperationsRecord.connection
        end
    end
  end
end

# frozen_string_literal: true

# Makes invoice saves that stopped part-way converge.
#
# A save writes its pending intent before it asks the reservation store to
# prepare. If the process dies before the intent is settled, the store may
# hold entries no invoice owns. Once an intent has been pending longer than
# the pickup age, this sweep marks it failed and writes its abort row, then
# delivers every outbox row that is still undelivered and not marked
# undeliverable.
#
# Each intent is resolved under the same (company_id, invoice_id) advisory
# lock the save holds, so a save that is still running (a slow prepare) makes
# the sweep wait, and the guarded update then finds the intent settled and
# writes nothing.
class RecoverInvoiceOperationIntentsJob < ApplicationJob
  queue_as :invoice_operations

  # How long a save may run before its intent is treated as crashed.
  PICKUP_AGE = 60.seconds
  # How long an intent may stay pending before operators are signalled. Kept
  # separate from PICKUP_AGE so resolving a crash never waits for the signal.
  SIGNAL_AGE = 10.minutes
  # How long the sweep waits for a live save's advisory lock before it leaves
  # that intent pending for the next run, so one stuck save cannot stall the
  # sweep for every other intent and every undelivered row.
  LOCK_WAIT_TIMEOUT = "5s"

  # reservations: lets specs hand in the adapter; without it delivery uses
  # the adapter for the current entry owner.
  def perform(pickup_age: PICKUP_AGE, signal_age: SIGNAL_AGE, reservations: nil)
    now = Time.current
    # Counted before resolving, so an intent this run fails is still reported.
    signal_stale(now - signal_age)
    pending_before(now - pickup_age).find_each { |intent| resolve(intent) }
    deliver_undelivered(reservations)
  end

  private

    def pending_before(cutoff)
      InvoiceOperationIntent.where(state: "pending").where(created_at: ...cutoff)
    end

    def signal_stale(cutoff)
      by_company = pending_before(cutoff).group(:company_id)
      oldest = by_company.minimum(:created_at)
      by_company.count.each do |company_id, count|
        Invoices::StaleOperationIntents.notify(company_id:, count:, oldest_created_at: oldest.fetch(company_id))
      end
    end

    # Each intent gets its own transaction and lock, and the lock wait is
    # bounded, so one company's live save or one failing intent never holds
    # up the others. An intent whose lock wait times out stays pending.
    def resolve(intent)
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(["SET LOCAL lock_timeout = ?", LOCK_WAIT_TIMEOUT])
        )
        Invoices::OperationLock.acquire!(ApplicationRecord.connection, company_id: intent.company_id, invoice_id: intent.invoice_id)
        moved = InvoiceOperationIntent
          .where(company_id: intent.company_id, invoice_id: intent.invoice_id, operation_id: intent.operation_id, state: "pending")
          .update_all(state: "failed", finished_at: Time.current)
        insert_abort_item(intent) if moved == 1
      end
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { company_id: intent.company_id, operation_id: intent.operation_id })
    end

    def insert_abort_item(intent)
      InvoiceOperationOutboxItem.record!(
        kind: "abort", company_id: intent.company_id, invoice_id: intent.invoice_id,
        operation_id: intent.operation_id, generation: intent.generation,
        disposition: intent.disposition, desired_entry_ids: intent.desired_entry_ids
      )
    end

    def deliver_undelivered(reservations)
      InvoiceOperationOutboxItem.where(delivered_at: nil, undeliverable_at: nil).order(:id).pluck(:id).each do |outbox_item_id|
        DeliverInvoiceOperationJob.perform_now(outbox_item_id, reservations:)
      end
    end
end

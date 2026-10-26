# frozen_string_literal: true

class DeliverInvoiceOperationJob < ApplicationJob
  queue_as :invoice_operations

  # reservations: lets the coordinator and specs hand in the adapter they
  # already hold; without it the adapter for the current entry owner is
  # chosen inside the delivery, so a failed lookup is counted as an attempt.
  def perform(outbox_item_id, reservations: nil)
    adapter_source = reservations ? -> { reservations } : method(:current_adapter)
    Invoices::OutboxDelivery.new(adapter_source:).deliver(outbox_item_id)
  end

  private

    def current_adapter
      Invoices::ReservationAdapters.for(TimekeepingOwnership.current)
    end
end

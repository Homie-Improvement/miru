# frozen_string_literal: true

module Invoices
  class BulkDeletionService < ApplicationService
    attr_reader :invoices

    # invoices is the relation to delete, already scoped to the caller's company.
    def initialize(invoices)
      @invoices = invoices
    end

    # Returns the ids of the invoices that could not be deleted because they
    # have recorded payments. During a handoff the fence raises
    # Timekeeping::BillingFence::OwnershipMoving and nothing is deleted.
    def process
      # One fenced transaction for the whole batch, so a handoff refuses all of
      # it rather than the invoices left after some were deleted.
      Timekeeping::BillingFence.transaction do
        invoices.reject { |invoice| destroy_in_savepoint(invoice) }.map(&:id)
      end
    end

    private

      # An invoice destroys its line items and taxes before its payments refuse
      # the destroy. Inside the shared transaction, Rails does not roll those
      # deletions back on its own, so each destroy gets a savepoint that is
      # rolled back when the destroy fails.
      def destroy_in_savepoint(invoice)
        destroyed = false
        Invoice.transaction(requires_new: true) do
          destroyed = invoice.destroy
          raise ActiveRecord::Rollback unless destroyed
        end
        destroyed
      end
  end
end

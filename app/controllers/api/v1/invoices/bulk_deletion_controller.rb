# frozen_string_literal: true

class Api::V1::Invoices::BulkDeletionController < Api::V1::ApplicationController
  def create
    authorize :create, policy_class: Invoices::BulkDeletionPolicy

    invoices = current_company.invoices.where(id: params[:invoices_ids])
    # One fenced transaction for the whole batch, so a handoff refuses all of
    # it rather than the invoices left after some were deleted.
    undeletable_invoice_ids = Timekeeping::BillingFence.transaction do
      invoices.reject { |invoice| destroy_in_savepoint(invoice) }.map(&:id)
    end

    if undeletable_invoice_ids.any?
      render json: {
        error: "Some invoices could not be deleted because they have recorded payments.",
        undeletable_invoice_ids:
      }, status: 422
    else
      head 204
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

# frozen_string_literal: true

# Refuses every save and destroy of a billing record while a Timekeeping
# handoff is in progress, by running the billing fence inside the record's own
# save or destroy transaction. Paths that write several records wrap them in
# Timekeeping::BillingFence.transaction so the lock comes first; this catches
# every other writer that runs callbacks.
#
# The callbacks are prepended so the share lock is taken before any other
# callback writes, such as the dependent destroys of an invoice.
module BillingFenced
  extend ActiveSupport::Concern

  included do
    before_save :admit_billing_write, prepend: true
    before_destroy :admit_billing_write, prepend: true
  end

  private

    def admit_billing_write
      Timekeeping::BillingFence.admit!
    end
end

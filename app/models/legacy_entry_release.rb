# frozen_string_literal: true

# The entries one legacy-store operation removes from its invoice, written by
# prepare in the invoice transaction and applied once by commit
# (Invoices::LegacyReservations).
class LegacyEntryRelease < ApplicationRecord
  validates :company_id, :invoice_id, :operation_id, presence: true
end

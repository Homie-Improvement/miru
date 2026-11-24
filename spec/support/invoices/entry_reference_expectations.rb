# frozen_string_literal: true

# Asserts that a record naming a missing or foreign timesheet entry is refused
# by the check the current entry owner runs (Invoices::EntryReferenceCheck),
# so one example proves the refusal in every Timekeeping ownership state:
#
# - :projection (legacy, rollback): the model validations refuse the id with
#   exactly one "not found" error on the attribute, as they always have;
# - :prepare_response (timekeeping): validation no longer reads the lagging
#   projection, so the save reaches the reservation boundary, which refuses
#   it with a not_found conflict and rolls every row back.
#
# Returns what the refusal looked like (the error hash, or the conflict
# reasons), so an example can check that a foreign id and a missing id are
# refused identically.
module InvoiceEntryReferenceExpectations
  # How an example asks for the refusal in the projection state: by
  # validating, by saving, or by saving past validation. Each must answer
  # false. In the timekeeping state the same request saves, with validation
  # kept or skipped alike.
  PROJECTION_REFUSALS = {
    valid: ->(record) { record.valid? },
    save: ->(record) { record.save },
    save_without_validation: ->(record) { record.save(validate: false) }
  }.freeze

  NOT_FOUND_ERROR = "not found"
  NOT_FOUND_REASON = "not_found"

  def expect_entry_reference_refused(record, attribute:, via: :valid)
    refuse = PROJECTION_REFUSALS.fetch(via)

    case Invoices::EntryReferenceCheck.for(TimekeepingOwnership.current)
    when :projection
      expect(refuse.call(record)).to be(false)
      expect(record.errors[attribute]).to eq([NOT_FOUND_ERROR])
      record.errors.to_hash
    when :prepare_response
      refusal = nil
      rows_before = invoice_entry_reference_rows
      stored_before = record.persisted? ? record.class.find(record.id).attributes : nil
      expect { record.save(validate: via != :save_without_validation) }
        .to raise_error(Invoices::OperationErrors::Refused) { |error| refusal = error }
      # The refusal rolls the whole save back: no invoice, line or link row
      # changes, and a stored record keeps its stored references.
      expect(invoice_entry_reference_rows).to eq(rows_before)
      expect(record.class.find(record.id).attributes).to eq(stored_before) if stored_before
      reasons = refusal.outcome.conflicts.map { |conflict| conflict.fetch(:reason) }.uniq
      expect(reasons).to eq([NOT_FOUND_REASON])
      reasons
    end
  end

  private

    # Every invoice, line and link row as stored, so a refused save can be
    # shown to have written nothing.
    def invoice_entry_reference_rows
      [Invoice, InvoiceLineItem, InvoiceLineItemTimeEntry].to_h do |model|
        [model.name, model.order(:id).map(&:attributes)]
      end
    end
end

RSpec.configure do |config|
  config.include InvoiceEntryReferenceExpectations
end

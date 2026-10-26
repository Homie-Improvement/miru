# frozen_string_literal: true

# Reads the stored invoice tax rows the way the billing fence specs compare
# them: each row's id plus its money columns, ordered by id. The invoice's
# scalar tax is a derived total, so only these rows show whether a refused
# request wrote a tax row.
module InvoiceTaxRowsHelper
  def stored_invoice_tax_rows(*invoice_ids)
    columns = ["id"] + Timekeeping::FinancialSnapshot::INVOICE_TAX_FIELDS.map(&:to_s)
    InvoiceTax.where(invoice_id: invoice_ids).order(:id).map { |row| row.attributes.slice(*columns) }
  end
end

RSpec.configure do |config|
  config.include InvoiceTaxRowsHelper, type: :request
end

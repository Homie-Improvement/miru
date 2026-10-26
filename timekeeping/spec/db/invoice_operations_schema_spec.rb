# frozen_string_literal: true

require "rails_helper"

# A handoff checkpoint carries invoice operation receipts between the monolith
# and Timekeeping, so both applications' invoice_operations tables must accept
# exactly the same rows.
RSpec.describe "Timekeeping invoice_operations table" do
  # The lines of a schema.rb create_table block, sorted, because the monolith
  # writes its columns in alphabetical order and Timekeeping in migration order.
  def invoice_operations_schema_lines(schema_path)
    block = File.read(schema_path)[/^  create_table "invoice_operations".*?^  end$/m]
    raise "no invoice_operations table in #{schema_path}" if block.nil?

    block.lines.map(&:strip).sort
  end

  def create_invoice_operation(company_id:, invoice_id: 7, state: "prepared")
    InvoiceOperation.create!(
      company_id:, invoice_id:, operation_id: SecureRandom.uuid, state:, disposition: "active",
      generation: 2, created_at: Time.current
    )
  end

  it "declares the same columns, defaults, index and checks as the monolith's table" do
    expect(invoice_operations_schema_lines(Rails.root.join("db/schema.rb")))
      .to eq(invoice_operations_schema_lines(Rails.root.join("../db/schema.rb")))
  end

  it "refuses a second prepared operation for one company's invoice" do
    create_invoice_operation(company_id: 1)

    expect { create_invoice_operation(company_id: 1) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "accepts the same invoice id prepared under two companies" do
    create_invoice_operation(company_id: 1)
    create_invoice_operation(company_id: 2)

    expect(InvoiceOperation.where(invoice_id: 7, state: "prepared").pluck(:company_id)).to contain_exactly(1, 2)
  end

  it "refuses a state outside prepared, committed and aborted" do
    expect { create_invoice_operation(company_id: 1, state: "bogus") }
      .to raise_error(ActiveRecord::StatementInvalid, /invoice_operations_state_check/)
  end
end

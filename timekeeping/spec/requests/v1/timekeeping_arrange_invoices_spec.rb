# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# The invoice catalogue the reference stub serves. Each invoice has one owning
# company, as in the monolith, so a spec that names another company's invoice
# can only see it refused.
RSpec.describe "TimekeepingProviderArrange invoice catalogue" do
  include_context "timekeeping entry writes"

  def owned_invoice_ids(company, invoice_ids)
    Timekeeping::ReferenceClient.configured.invoice_holders(company_id: company, invoice_ids:).owned_ids
  end

  it "refuses to arrange one invoice id for a second company" do
    company = timekeeping_arrange.company
    other_company = timekeeping_arrange.company
    expect(timekeeping_arrange.invoice(company:, invoice_id: 801)).to eq(801)

    expect { timekeeping_arrange.invoice(company: other_company, invoice_id: 801) }
      .to raise_error(ArgumentError, /801/)
    expect(timekeeping_arrange.invoice(company:, invoice_id: 801)).to eq(801)
  end

  it "lists an arranged invoice for its own company only" do
    company = timekeeping_arrange.company
    other_company = timekeeping_arrange.company
    timekeeping_arrange.invoice(company:, invoice_id: 802)
    timekeeping_arrange.invoice(company: other_company, invoice_id: 803)

    expect(owned_invoice_ids(company, [803, 802, 990_001])).to eq([802])
    expect(owned_invoice_ids(other_company, [802, 803])).to eq([803])
  end

  it "registers the invoice of a reserved entry for that entry's company" do
    company = timekeeping_arrange.company
    other_company = timekeeping_arrange.company
    timekeeping_arrange.reserved_entry(company:, invoice_id: 804)

    expect(owned_invoice_ids(company, [804])).to eq([804])
    expect(owned_invoice_ids(other_company, [804])).to eq([])
    expect { timekeeping_arrange.reserved_entry(company: other_company, invoice_id: 804) }
      .to raise_error(ArgumentError, /804/)
  end
end

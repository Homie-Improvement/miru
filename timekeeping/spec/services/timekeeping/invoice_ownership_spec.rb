# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::InvoiceOwnership do
  context "more tests 2" do
    include_context "timekeeping entry writes"

    # "In the Timekeeping service, InvoiceOwnership.owned? answers false when another company holds an invoice row or intent row for the id, even when the requester has its own invoice_operations row naming that id, matching the local owner."
    it "refuses another company's invoice even though a stale own invoice_operations row names that id" do
      company = timekeeping_arrange.company
      other_company = timekeeping_arrange.company
      timekeeping_arrange.invoice(company: other_company, invoice_id: 881)
      # A row an unchecked prepare stored earlier: it names the requester and the other company's invoice.
      InvoiceOperation.create!(company_id: company, invoice_id: 881, operation_id: SecureRandom.uuid,
                               actor_name: "invoice-boundary", state: "committed", desired_entry_ids: [],
                               disposition: "active", generation: 1, created_at: Time.current)

      expect(described_class.owned?(company_id: company, invoice_id: 881)).to be(false)
      expect(described_class.owned?(company_id: other_company, invoice_id: 881)).to be(true)
    end
  end

  context "more tests 3" do
    include_context "timekeeping entry writes"

    # "In the Timekeeping service, InvoiceOwnership.owned? answers false when another company holds an invoice row or intent row for the id, even when the requester has its own invoice_operations row naming that id, matching the local owner."
    # The other company's invoice save has committed its intent but not its invoice row, so the monolith lists
    # the id for nobody in invoices and reports it as held by another company.
    it "refuses an id another company holds only as an in-flight intent even though a stale own invoice_operations row names it" do
      company = timekeeping_arrange.company
      InvoiceOperation.create!(company_id: company, invoice_id: 882, operation_id: SecureRandom.uuid,
                               actor_name: "invoice-boundary", state: "committed", desired_entry_ids: [],
                               disposition: "active", generation: 1, created_at: Time.current)
      WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(company_id: company, edit_days: 30, users: [], projects: [], missing_project_ids: [],
                            agents: [], owned_agent_ids: [], invoices: [], foreign_invoice_ids: [882])
      )

      expect(described_class.owned?(company_id: company, invoice_id: 882)).to be(false)
    end
  end

  context "more tests 4" do
    include_context "timekeeping entry writes"

    # "In the Timekeeping service, InvoiceOwnership.owned? answers false when another company holds an invoice row or intent row for the id, even when the requester has its own invoice_operations row naming that id, matching the local owner."
    # A monolith deployed before the new field cannot say whether another company holds the id, so falling
    # back to the own row here would re-open the cross-company admission.
    it "raises Unavailable instead of trusting a stale own row when an older monolith omits foreign_invoice_ids" do
      company = timekeeping_arrange.company
      InvoiceOperation.create!(company_id: company, invoice_id: 883, operation_id: SecureRandom.uuid,
                               actor_name: "invoice-boundary", state: "committed", desired_entry_ids: [],
                               disposition: "active", generation: 1, created_at: Time.current)
      WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(company_id: company, edit_days: 30, users: [], projects: [], missing_project_ids: [],
                            agents: [], owned_agent_ids: [], invoices: [])
      )

      expect { described_class.owned?(company_id: company, invoice_id: 883) }
        .to raise_error(Timekeeping::ReferenceClient::Unavailable)
    end
  end

  context "more tests 5" do
    include_context "timekeeping entry writes"

    # "In the Timekeeping service, InvoiceOwnership.owned? answers false when another company holds an invoice row or intent row for the id, even when the requester has its own invoice_operations row naming that id, matching the local owner."
    # A string id cannot be matched against the Integer invoice id, so reading it would silently miss the other
    # company's hold and let the own row admit the invoice.
    it "raises Unavailable instead of trusting a stale own row when foreign_invoice_ids is malformed" do
      company = timekeeping_arrange.company
      InvoiceOperation.create!(company_id: company, invoice_id: 884, operation_id: SecureRandom.uuid,
                               actor_name: "invoice-boundary", state: "committed", desired_entry_ids: [],
                               disposition: "active", generation: 1, created_at: Time.current)
      WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(company_id: company, edit_days: 30, users: [], projects: [], missing_project_ids: [],
                            agents: [], owned_agent_ids: [], invoices: [], foreign_invoice_ids: ["884"])
      )

      expect { described_class.owned?(company_id: company, invoice_id: 884) }
        .to raise_error(Timekeeping::ReferenceClient::Unavailable)
    end
  end

  context "more tests 6" do
    include_context "timekeeping entry writes"

    it "owned? still counts the requester's own invoice_operations row for an id no company holds, after asking the monolith" do
      company = timekeeping_arrange.company
      InvoiceOperation.create!(company_id: company, invoice_id: 783, operation_id: SecureRandom.uuid,
                               actor_name: "invoice-boundary", state: "committed", desired_entry_ids: [],
                               disposition: "active", generation: 1, created_at: Time.current)
      # A hard-deleted invoice: nobody owns it and nobody else holds it.
      reference = WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return do |request|
        company_id = Integer(request.uri.path[%r{/companies/(\d+)/}, 1], 10)
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: JSON.generate(company_id:, edit_days: 30, users: [], projects: [], missing_project_ids: [], agents: [],
                              owned_agent_ids: [], invoices: [], foreign_invoice_ids: []) }
      end

      expect(described_class.owned?(company_id: company, invoice_id: 783)).to be(true)
      # The other holders are checked before the own row counts, so the monolith must be asked.
      expect(reference).to have_been_requested.once
      expect(described_class.owned?(company_id: company, invoice_id: 784)).to be(false)
    end
  end

  context "more tests 7" do
    include_context "timekeeping entry writes"

    it "owned? raises Unavailable instead of trusting the own invoice_operations row when the reference endpoint fails" do
      company = timekeeping_arrange.company
      InvoiceOperation.create!(company_id: company, invoice_id: 785, operation_id: SecureRandom.uuid,
                               actor_name: "invoice-boundary", state: "committed", desired_entry_ids: [],
                               disposition: "active", generation: 1, created_at: Time.current)
      WebMock.stub_request(:get, TimekeepingProviderArrange::REFERENCE_HOST).to_return(status: 500, body: "")

      expect { described_class.owned?(company_id: company, invoice_id: 785) }
        .to raise_error(Timekeeping::ReferenceClient::Unavailable)
    end
  end
end

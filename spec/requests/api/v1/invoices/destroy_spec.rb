# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Invoices#destroy", type: :request do
  let(:invoice) { create :invoice_with_invoice_line_items }
  let(:client) { invoice.client }
  let(:company) { invoice.company }
  let(:user) { create :user, current_workspace_id: company.id }

  context "when the user is an admin" do
    before do
      create(:employment, company:, user:)
      user.add_role :admin, company
      sign_in user
    end

    describe "#destroy" do
      it "deletes invoice successfully" do
        expect do
          send_request :delete, api_v1_invoice_path(id: invoice.id), headers: auth_headers(user)
        end.not_to change(Invoice, :count)

        expect(response).to be_successful
        expect(invoice.reload).to be_discarded
        expect(company.invoices.discarded.pluck(:id).include?(invoice.id)).to eq(true)
      end
    end
  end

  context "when the user is an employee" do
    before do
      create(:employment, company:, user:)
      user.add_role :employee, company
      sign_in user
    end

    it "is not be permitted to delete an invoice" do
      send_request :delete, api_v1_invoice_path(id: invoice.id), headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
      expect(invoice.reload).not_to be_discarded
    end
  end

  context "when the user is an book keeper" do
    before do
      create(:employment, company:, user:)
      user.add_role :book_keeper, company
      sign_in user
    end

    it "is not be permitted to delete an invoice" do
      send_request :delete, api_v1_invoice_path(id: invoice.id), headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
      expect(invoice.reload).not_to be_discarded
    end
  end

  context "when unauthenticated" do
    it "is not be permitted to delete an invoice" do
      send_request :delete, api_v1_invoice_path(id: invoice.id)
      expect(response).to have_http_status(:unauthorized)
      expect(json_response["error"]).to eq(I18n.t("devise.failure.unauthenticated"))
    end
  end
end

RSpec.describe "Api::V1::Invoices#destroy", type: :request do
  let(:takeover_company) { create(:company, base_currency: "USD") }
  let(:takeover_client) { create(:client, company: takeover_company) }
  let(:takeover_admin) { create(:user, current_workspace_id: takeover_company.id) }
  let(:takeover_project) { create(:project, client: takeover_client, billable: true) }

  before do
    create(:employment, company: takeover_company, user: takeover_admin)
    takeover_admin.add_role :admin, takeover_company
    sign_in takeover_admin
  end

  # "A discarded draft (L2): \"Its reservations are released.\""
  # "a locked entry on a discarded non-draft can be taken by a new invoice"
  # Scenario: the old sent invoice keeps a retained claim after the draft takes its entry. If the
  # takeover does not drop that claim, the draft's later discard leaves the entry locked forever.
  it "unlocks an entry a discarded draft took from a discarded sent invoice" do
    entry = create(:timesheet_entry, user: takeover_admin, project: takeover_project,
      bill_status: :unbilled, locked: false, work_date: Date.current, duration: 60)
    sent = create(:invoice, company: takeover_company, client: takeover_client, status: :sent)
    create(:invoice_line_item, invoice: sent, timesheet_entry: entry, rate: 100, quantity: 60)
    entry.update_columns(locked: true)

    send_request :delete, api_v1_invoice_path(sent), headers: auth_headers(takeover_admin)
    expect(response).to have_http_status(:success)
    expect(entry.reload.locked).to be(true)

    draft = create(:invoice, company: takeover_company, client: takeover_client)
    create(:invoice_line_item, invoice: draft, timesheet_entry: entry, rate: 100, quantity: 60)
    expect(entry.reload.locked).to be(true)

    send_request :delete, api_v1_invoice_path(draft), headers: auth_headers(takeover_admin)

    expect(response).to have_http_status(:success)
    expect(draft.reload).to be_discarded
    expect(entry.reload.locked).to be(false)
  end
end

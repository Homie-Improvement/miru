# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"
require_relative "../../../spec/support/timekeeping/contract"
require_relative "../../../spec/support/timekeeping/client"
require_relative "../../../spec/contracts/timekeeping/reservations_examples"
require_relative "../../../spec/contracts/timekeeping/idempotency_examples"

# Runs the monolith's shared reservation and idempotency examples, unchanged,
# against the real Timekeeping app.
RSpec.describe "Timekeeping reservations provider" do
  include_context "timekeeping entry writes"

  let(:timekeeping_client) { TimekeepingRackClient.new(Rails.application) }

  it_behaves_like "timekeeping reservations contract"
  it_behaves_like "timekeeping idempotency contract", contracts: [:reservations]

  context "more tests 2" do
  # "A shared contract example that sends a prepare and a mark-billed carrying another company's invoice id gets 404 not_found and no writes on all three providers, LocalOwner included."
  it "on the Timekeeping service, a prepare and a mark-billed carrying another company's invoice id get 404 not_found and no writes" do
    arrange = timekeeping_arrange
    reservations = TimekeepingContract.load(:reservations)
    not_found = reservations.dig("errors", "not_found")
    company = arrange.company
    other_company = arrange.company
    service = arrange.service_identity(company:, name: "invoice-boundary", operations: reservations.fetch("routes").keys)
    foreign_invoice = arrange.invoice(company: other_company, invoice_id: 601)
    own_invoice = arrange.invoice(company:, invoice_id: 501)
    user = arrange.user(company:, role: "employee")
    entry = arrange.entry(company:, user:, project: arrange.project(company:))
    foreign_entry = arrange.reserved_entry(company: other_company, invoice_id: foreign_invoice, state: "committed")
    command = lambda do |route, body, **path_params|
      params = { company_id: company }.merge(path_params)
      path = reservations.dig("routes", route, "path").gsub(/\{(\w+)\}/) { params.fetch(Regexp.last_match(1).to_sym) }
      timekeeping_client.call("POST", path, headers: { "Authorization" => "Bearer #{service}" },
                                            body: { "generation" => arrange.current_generation }.merge(body))
    end
    prepare_key = SecureRandom.uuid
    bill_key = SecureRandom.uuid
    prepare_body = { "invoice_id" => foreign_invoice, "operation_id" => prepare_key, "disposition" => "active", "entries" => [entry] }
    outbox_before = arrange.outbox_size
    receipts_before = arrange.stored_receipts(company:)

    prepared = command.call("prepare", prepare_body)
    billed = command.call("mark_billed", { "operation_id" => bill_key }, invoice_id: foreign_invoice)

    expect([prepared.status, prepared.body]).to eq([404, not_found.fetch("body")])
    expect([billed.status, billed.body]).to eq([404, not_found.fetch("body")])
    expect(arrange.reservations_for(entry)).to eq([])
    expect(arrange.entry_locked(entry)).to be(false)
    expect(arrange.stored_entry(foreign_entry).fetch("bill_status")).to eq("unbilled")
    expect(arrange.outbox_size).to eq(outbox_before)
    # The service keys mark-billed receipts by target, so only a count shows a receipt stored for the refused invoice.
    expect(arrange.stored_receipts(company:)).to eq(receipts_before)
    expect(command.call("prepare", prepare_body).status).to eq(404)
    expect(command.call("mark_billed", { "operation_id" => bill_key }, invoice_id: foreign_invoice).status).to eq(404)
    expect(arrange.stored_receipts(company:)).to eq(receipts_before)

    own = command.call("prepare", prepare_body.merge("invoice_id" => own_invoice))
    expect([own.status, own.body.fetch("state")]).to eq([200, "prepared"])
  end
  end
end

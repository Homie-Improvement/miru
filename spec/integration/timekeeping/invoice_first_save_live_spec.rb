# frozen_string_literal: true

require "rails_helper"

# A new invoice's first save asks Timekeeping to prepare before the invoice row
# commits (Invoices::OperationCoordinator runs from the reservation boundary's
# before_committed!). Timekeeping then asks the monolith's reference endpoint
# who owns the invoice, on a connection that cannot see the uncommitted row,
# so only the pending intent the coordinator commits first can vouch for it.
# These examples run that ordering against a real Timekeeping server whose
# reference endpoint answers from the monolith's own records
# (TimekeepingLiveInstance::ReferenceStub). They need TIMEKEEPING_LIVE=1 and
# TIMEKEEPING_DATABASE_URL, so the default suite skips them.
RSpec.describe "A new invoice's first save against a live Timekeeping", :without_transaction, committed_data: true do
  before(:all) do
    skip "Set TIMEKEEPING_LIVE=1 to boot a real Timekeeping server" unless ENV["TIMEKEEPING_LIVE"] == "1"

    TestDatabaseGuard.require_test_database_url!(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    WebMock.disable_net_connect!(allow_localhost: true)
    TimekeepingOwnership.ensure_initial!
    @first_save_reference = TimekeepingLiveInstance::ReferenceStub.new
    @first_save_timekeeping = TimekeepingLiveInstance.start(
      reference_stub: @first_save_reference, admission_generation: TimekeepingOwnership.current.generation
    )
    @first_save_reference.service_token = @first_save_timekeeping.service_token
  end

  after(:all) { @first_save_timekeeping&.stop }

  before { WebMock.disable_net_connect!(allow_localhost: true) }

  after do
    next unless ENV["TIMEKEEPING_LIVE"] == "1"

    TestDatabaseGuard.require_test_database_url!(ENV.fetch("TIMEKEEPING_DATABASE_URL"))
    TimekeepingDatabaseReset.reset!(nil, env: ENV)
  end

  # The reservation adapter the monolith uses once Timekeeping owns entries,
  # pointed at the live server and signing with the key that server trusts.
  def first_save_client
    timekeeping = @first_save_timekeeping
    Timekeeping::ReservationClient.new(
      http: Timekeeping::ReservationHttp.new(base_url: timekeeping.base_url),
      credential: lambda do |company_id:, operation:|
        Timekeeping::ServiceToken.mint(company_id:, operations: [operation], private_key: timekeeping.private_key)
      end
    )
  end

  # Inserts the invoice row without its model callbacks, so the reservation
  # boundary of the entry owner configured for the test database never runs
  # beside the coordinator these examples drive.
  def first_save_insert_invoice(company)
    invoice = build(:invoice, company:, client: create(:client, company:))
    invoice.valid?
    Invoice.insert!(invoice.attributes.except("id", "created_at", "updated_at"), returning: :id).first.fetch("id")
  end

  def first_save_request(company, invoice_id)
    Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id:, operation_id: SecureRandom.uuid,
      generation: TimekeepingOwnership.current.generation, disposition: "active", entries: []
    )
  end

  # Whether a connection other than the invoice transaction's sees the row.
  def first_save_invoice_visible_elsewhere?(invoice_id)
    committed_data_thread { Invoice.unscoped.exists?(id: invoice_id) }.value
  end

  def first_save_outbox_item(request, kind)
    InvoiceOperationOutboxItem.uncached do
      InvoiceOperationOutboxItem.find_by(company_id: request.company_id, operation_id: request.operation_id, kind:)
    end
  end

  it "prepares and commits a new invoice whose row Timekeeping cannot see yet" do
    company = create(:company)
    client = first_save_client
    request = nil
    prepared = nil
    visible_during_prepare = nil

    ApplicationRecord.transaction do
      invoice_id = first_save_insert_invoice(company)
      request = first_save_request(company, invoice_id)
      prepared = Invoices::OperationCoordinator.new(reservations: client)
        .call(request, holding: { entry_ids: [], disposition: "active" })
      visible_during_prepare = first_save_invoice_visible_elsewhere?(invoice_id)
    end

    expect(visible_during_prepare).to be(false)
    expect(prepared.state).to eq("prepared")
    expect(first_save_outbox_item(request, "commit").delivered_at).to be_present
    expect(client.prepare(request).state).to eq("committed")
  end

  it "aborts a new invoice whose save rolled back, so its abort item is delivered and not retried for ever" do
    company = create(:company)
    client = first_save_client
    request = nil
    prepared = nil

    ApplicationRecord.transaction do
      invoice_id = first_save_insert_invoice(company)
      request = first_save_request(company, invoice_id)
      prepared = Invoices::OperationCoordinator.new(reservations: client)
        .call(request, holding: { entry_ids: [], disposition: "active" })
      raise ActiveRecord::Rollback
    end

    expect(prepared.state).to eq("prepared")
    expect(Invoice.unscoped.exists?(id: request.invoice_id)).to be(false)
    abort_item = first_save_outbox_item(request, "abort")
    expect(abort_item.delivered_at).to be_present
    expect(abort_item.undeliverable_at).to be_nil
    expect(client.prepare(request).state).to eq("aborted")
  end
end

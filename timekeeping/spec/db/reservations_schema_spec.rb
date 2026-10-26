# frozen_string_literal: true

require "rails_helper"

# The reservation rule of docs/architecture/timekeeping-soa.md section 7.2:
# at most one committed and at most one provisional reservation per entry,
# and a reservation only ever points at an entry of its own company.
RSpec.describe "Timekeeping reservations table" do
  def create_schema_spec_entry(company_id)
    Entry.create!(
      company_id:, project_id: 1, user_id: 1, work_date: Date.new(2026, 1, 5),
      duration: 60.0, bill_status: "unbilled"
    )
  end

  def reserve(entry, state:, company_id: entry.company_id)
    Reservation.create!(
      company_id:, entry_id: entry.id, invoice_id: 1, state:,
      disposition: "active", operation_id: SecureRandom.uuid, created_at: Time.current
    )
  end

  let(:entry) { create_schema_spec_entry(1) }

  it "accepts one provisional and one committed reservation for the same entry" do
    reserve(entry, state: "provisional")
    reserve(entry, state: "committed")

    expect(Reservation.where(company_id: 1, entry_id: entry.id).count).to eq(2)
  end

  it "refuses a second committed reservation for the same entry" do
    reserve(entry, state: "committed")

    expect { reserve(entry, state: "committed") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a second provisional reservation for the same entry" do
    reserve(entry, state: "provisional")

    expect { reserve(entry, state: "provisional") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a reservation whose company differs from its entry's" do
    other_company_entry = create_schema_spec_entry(2)

    expect { reserve(other_company_entry, state: "committed", company_id: 1) }
      .to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "refuses a state outside provisional and committed" do
    expect { reserve(entry, state: "released") }.to raise_error(ActiveRecord::StatementInvalid)
  end
end

# Section 7.2's invoice_operations, and the reservations they own. An
# operation is identified by its company, calling service and operation id.
RSpec.describe "Timekeeping invoice operations table" do
  def create_operation_schema_spec_entry(company_id)
    Entry.create!(
      company_id:, project_id: 1, user_id: 1, work_date: Date.new(2026, 1, 5),
      duration: 60.0, bill_status: "unbilled"
    )
  end

  def create_schema_spec_operation(company_id: 1, invoice_id: 501, actor_name: "invoice-boundary",
                                   operation_id: SecureRandom.uuid, state: "prepared")
    InvoiceOperation.create!(
      company_id:, invoice_id:, actor_name:, operation_id:, state:, desired_entry_ids: [],
      disposition: "active", generation: 1, created_at: Time.current
    )
  end

  def reserve_for_operation(entry, operation_id:, invoice_operation_id: nil)
    Reservation.create!(
      company_id: entry.company_id, entry_id: entry.id, invoice_id: 501, state: "provisional",
      disposition: "active", operation_id:, invoice_operation_id:, created_at: Time.current
    )
  end

  let(:entry) { create_operation_schema_spec_entry(1) }

  it "refuses an owned reservation whose operation_id differs from its operation's" do
    operation = create_schema_spec_operation

    expect { reserve_for_operation(entry, operation_id: SecureRandom.uuid, invoice_operation_id: operation.id) }
      .to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "refuses an owned reservation whose operation belongs to another company" do
    operation = create_schema_spec_operation(company_id: 2)

    expect { reserve_for_operation(entry, operation_id: operation.operation_id, invoice_operation_id: operation.id) }
      .to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "accepts an owned reservation that carries its operation's id" do
    operation = create_schema_spec_operation

    reserve_for_operation(entry, operation_id: operation.operation_id, invoice_operation_id: operation.id)

    expect(Reservation.where(invoice_operation_id: operation.id).count).to eq(1)
  end

  it "accepts any operation_id on a reservation with no owning operation" do
    reserve_for_operation(entry, operation_id: SecureRandom.uuid)

    expect(Reservation.where(company_id: 1, entry_id: entry.id, invoice_operation_id: nil).count).to eq(1)
  end

  it "refuses a second prepared operation for the same company and invoice" do
    create_schema_spec_operation

    expect { create_schema_spec_operation }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "accepts a new prepared operation once the invoice's earlier one is finished" do
    create_schema_spec_operation(state: "committed")
    create_schema_spec_operation

    expect(InvoiceOperation.where(company_id: 1, invoice_id: 501).count).to eq(2)
  end

  it "accepts prepared operations for the same invoice id in two companies" do
    create_schema_spec_operation(company_id: 1)
    create_schema_spec_operation(company_id: 2)

    expect(InvoiceOperation.where(invoice_id: 501, state: "prepared").count).to eq(2)
  end

  it "accepts one operation id in two companies and for two services of one company" do
    operation_id = SecureRandom.uuid
    create_schema_spec_operation(company_id: 1, invoice_id: 501, operation_id:)
    create_schema_spec_operation(company_id: 2, invoice_id: 501, operation_id:)
    create_schema_spec_operation(company_id: 1, invoice_id: 502, operation_id:, actor_name: "agent-destroy")

    expect(InvoiceOperation.where(operation_id:).count).to eq(3)
  end

  it "refuses the same operation id twice for one company and service" do
    operation_id = SecureRandom.uuid
    create_schema_spec_operation(invoice_id: 501, operation_id:, state: "committed")

    expect { create_schema_spec_operation(invoice_id: 502, operation_id:) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end

# A service has a name and no numeric id: service rows carry actor_name, user
# rows carry actor_id, and each kind keeps its own unique receipt key.
RSpec.describe "Timekeeping service actor rows" do
  def create_schema_spec_audit(actor_type:, actor_id: nil, actor_name: nil)
    AuditEvent.create!(
      company_id: 1, entry_id: 1, actor_type:, actor_id:, actor_name:, action: "prepare",
      before: { "locked" => false }, after: { "locked" => true },
      entry_created_at: Time.current, created_at: Time.current
    )
  end

  def receipt_attributes
    { company_id: 1, operation: "commit", key: "operation-1", fingerprint: "f", status: 200, body: "{}",
      created_at: Time.current }
  end

  it "accepts a service audit row with an actor_name and no actor_id" do
    create_schema_spec_audit(actor_type: "service", actor_name: "invoice-boundary")

    expect(AuditEvent.where(actor_name: "invoice-boundary", actor_id: nil).count).to eq(1)
  end

  it "refuses a service audit row without an actor_name" do
    expect { create_schema_spec_audit(actor_type: "service", actor_id: 7) }
      .to raise_error(ActiveRecord::StatementInvalid, /audit_events_actor_check/)
  end

  it "refuses a user audit row without an actor_id" do
    expect { create_schema_spec_audit(actor_type: "user", actor_name: "invoice-boundary") }
      .to raise_error(ActiveRecord::StatementInvalid, /audit_events_actor_check/)
  end

  it "still refuses a second user receipt with the same receipt key" do
    IdempotencyReceipt.create!(receipt_attributes.merge(actor_type: "user", actor_id: 7))

    expect { IdempotencyReceipt.create!(receipt_attributes.merge(actor_type: "user", actor_id: 7)) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a second service receipt with the same company, service name, operation and key" do
    ServiceIdempotencyReceipt.create!(receipt_attributes.merge(actor_name: "invoice-boundary"))

    expect { ServiceIdempotencyReceipt.create!(receipt_attributes.merge(actor_name: "invoice-boundary")) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "accepts the same service receipt key for another service name" do
    ServiceIdempotencyReceipt.create!(receipt_attributes.merge(actor_name: "invoice-boundary"))
    ServiceIdempotencyReceipt.create!(receipt_attributes.merge(actor_name: "agent-destroy"))

    expect(ServiceIdempotencyReceipt.where(key: "operation-1").count).to eq(2)
  end
end

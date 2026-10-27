# frozen_string_literal: true

# Setup the prepared adapter examples share. The reservations and
# invoice_operations tables have no model in the monolith, so they are read
# by SQL.
module PreparedReservationsSpecSupport
  def prepared_spec_entry(company, bill_status: "unbilled")
    project = create(:project, client: create(:client, company:))
    Timekeeping::LocalEntry.create!(company_id: company.id, user_id: create(:user).id, project_id: project.id,
                                    work_date: Date.current, duration: 60.0, bill_status:)
  end

  def prepared_spec_invoice(company)
    create(:invoice, company:, client: create(:client, company:))
  end

  def prepared_spec_request(company, invoice, entries, disposition: "active", operation_id: SecureRandom.uuid)
    Invoices::ReservationRequest.new(
      company_id: company.id, invoice_id: invoice.id, operation_id:,
      generation: TimekeepingOwnership.current.generation, disposition:, entries:
    )
  end

  # [entry_id, invoice_id, state, disposition] for every reservation of the company.
  def prepared_spec_reservations(company)
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id])
      SELECT entry_id, invoice_id, state, disposition FROM reservations
      WHERE company_id = ? ORDER BY entry_id, invoice_id, state
    SQL
    ActiveRecord::Base.connection.select_all(sql).cast_values
  end

  # [state, desired_entry_ids, disposition] for every operation of the invoice.
  def prepared_spec_operations(company, invoice)
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id, invoice.id])
      SELECT state, desired_entry_ids, disposition FROM invoice_operations
      WHERE company_id = ? AND invoice_id = ? ORDER BY id
    SQL
    ActiveRecord::Base.connection.select_all(sql).cast_values
  end

  def prepared_spec_outbox_count(entry)
    Timekeeping::LocalOutboxEntry.where(company_id: entry.company_id, entry_id: entry.id).count
  end

  def prepared_spec_commit_flow(adapter, request)
    expect(adapter.prepare(request).state).to eq("prepared")
    expect(adapter.commit(request).state).to eq("committed")
  end
end

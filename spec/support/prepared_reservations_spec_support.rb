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

  # Every row a prepare, commit, abort or mark_billed could write or change:
  # the company's reservations with their operation identity, its
  # operations, the entries' versions, and the outbox of the company and of
  # every company. A refused or repeated call must leave all of it as it was.
  def prepared_spec_snapshot(company, entries)
    reservations_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id])
      SELECT entry_id, invoice_id, state, disposition, operation_id, invoice_operation_id FROM reservations
      WHERE company_id = ? ORDER BY entry_id, invoice_id, state
    SQL
    operations_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, company.id])
      SELECT invoice_id, operation_id, state FROM invoice_operations WHERE company_id = ? ORDER BY id
    SQL
    {
      reservations: ActiveRecord::Base.connection.select_rows(reservations_sql),
      operations: ActiveRecord::Base.connection.select_rows(operations_sql),
      versions: Timekeeping::LocalEntry.where(id: entries.map(&:id)).order(:id).pluck(:id, :version),
      company_outbox: Timekeeping::LocalOutboxEntry.where(company_id: company.id).count,
      outbox: Timekeeping::LocalOutboxEntry.count
    }
  end

  def prepared_spec_outbox_count(entry)
    Timekeeping::LocalOutboxEntry.where(company_id: entry.company_id, entry_id: entry.id).count
  end

  def prepared_spec_commit_flow(adapter, request)
    expect(adapter.prepare(request).state).to eq("prepared")
    expect(adapter.commit(request).state).to eq("committed")
  end
end

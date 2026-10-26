# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The first cutover's checkpoint source, per docs/architecture/timekeeping-soa.md
    # sections 10.3 and 10.4. The legacy monolith has no reservation rows, so
    # this source reads timesheet_entries, the invoice links and the entry
    # audits, runs the pre-flight for every company, and derives reservations
    # and the listed corrections. The decisions live in ReservationDerivation
    # and LegacyAuditConversion; this class only reads.
    #
    # Everything is read in one REPEATABLE READ, read only transaction, so the
    # pre-flight and the copy see one state and no table can be written.
    class LegacySource
      # The cutover found legacy states with no recorded disposition. Carries
      # every failing company's list, so one run shows everything to settle.
      class Refused < Store::Error
        # { company_id, or a recorded company name that matches no single
        # company => [message] }
        attr_reader :refusals

        def initialize(refusals)
          @refusals = refusals
          details = refusals.map { |company, messages| "company #{company}: #{messages.join('; ')}" }
          super("the first cutover is refused: #{details.join(' | ')}")
        end
      end

      ENTRIES_SQL = <<~SQL.squish
        SELECT timesheet_entries.*, clients.company_id AS join_company_id
        FROM timesheet_entries
        JOIN projects ON projects.id = timesheet_entries.project_id
        JOIN clients ON clients.id = projects.client_id
        ORDER BY timesheet_entries.id
      SQL
      # Direct line items and grouped line-item join rows both reference
      # entries, as in SeedDispositionRecorder.invoice_links.
      LINKS_SQL = <<~SQL.squish
        SELECT invoice_id, timesheet_entry_id FROM invoice_line_items WHERE timesheet_entry_id IS NOT NULL
        UNION ALL
        SELECT invoice_line_items.invoice_id, invoice_line_item_time_entries.timesheet_entry_id
        FROM invoice_line_item_time_entries
        JOIN invoice_line_items ON invoice_line_items.id = invoice_line_item_time_entries.invoice_line_item_id
        ORDER BY 1, 2
      SQL
      INVOICES_SQL = "SELECT id, company_id, invoice_number, status, discarded_at FROM invoices ORDER BY id"
      COMPANIES_SQL = "SELECT id, name FROM companies ORDER BY id"
      AUDITS_SQL = <<~SQL.squish
        SELECT id, action, associated_type, associated_id, auditable_id, user_type, user_id, username,
          audited_changes, created_at
        FROM audits WHERE auditable_type = 'TimesheetEntry' ORDER BY id
      SQL
      # The legacy table stores these enums as integers; the checkpoint holds
      # their names.
      ENUM_COLUMNS = { "bill_status" => TimesheetEntry.bill_statuses, "review_status" => TimesheetEntry.review_statuses }.freeze

      def initialize(connection:, recorded_disposition:)
        @connection = connection
        @recorded_companies = recorded_disposition.to_h.fetch("companies", nil).to_h
      end

      # Returns { checkpoint:, corrections: }, or raises Refused before any
      # row is built. A transaction the caller already opened is refused by
      # Rails, which cannot set the isolation level inside one, so the
      # pre-flight never reads a snapshot the caller fixed earlier.
      def export(generation:, captured_at:)
        connection.transaction(isolation: :repeatable_read) do
          connection.execute("SET TRANSACTION READ ONLY")
          build(generation:, captured_at:)
        end
      end

      private

        attr_reader :connection, :recorded_companies

        def build(generation:, captured_at:)
          companies = cast_rows(COMPANIES_SQL)
          entries = RowReader.select_rows(connection, ENTRIES_SQL).map { |row| legacy_entry(row) }
          invoices = cast_rows(INVOICES_SQL)
          links = read_links(invoices)
          invoice_numbers = invoices.group_by { |_id, company_id| company_id }
            .transform_values { |rows| rows.to_h { |id, _company_id, number| [id, number] } }

          refusals = Hash.new { |hash, key| hash[key] = [] }
          recorded_by_company = recorded_by_company(companies, refusals)
          derived = companies.map do |company_id, _name|
            result = derive_company(company_id, entries, links, invoice_numbers, recorded_by_company, generation, captured_at)
            refusals[company_id].concat(result[:refusals]) if result[:refusals].any?
            result
          end

          entry_rows = entries.pluck(:row)
          audits = LegacyAuditConversion.convert(audits: read_audits, entries_by_id: entry_rows.index_by { |row| row["id"] })
          audits[:refusals].each { |company, messages| refusals[company].concat(messages) }
          raise Refused, refusals.to_h if refusals.any?

          {
            checkpoint: Checkpoint.build(tables: {
              "entries" => entry_rows,
              "reservations" => derived.flat_map { |result| result[:reservations] },
              "invoice_operations" => [],
              "entry_audits" => audits[:rows],
              "idempotency_records" => [],
              "service_idempotency_receipts" => []
            }),
            corrections: derived.flat_map { |result| result[:corrections] }
          }
        end

        def derive_company(company_id, entries, links, invoice_numbers, recorded_by_company, generation, captured_at)
          company_entries = entries.select { |entry| entry[:join_company_id] == company_id }
          entry_ids = company_entries.to_set { |entry| entry[:id] }
          company_links = links.select { |link| link[:invoice_company_id] == company_id || entry_ids.include?(link[:entry_id]) }

          ReservationDerivation.derive(
            company_id:, entries: company_entries, links: company_links,
            invoice_numbers: invoice_numbers.fetch(company_id, {}),
            recorded_invoices: recorded_by_company.fetch(company_id, {}),
            generation:, captured_at:
          )
        end

        # The record is keyed by company name. A name must match exactly one
        # company, or its listing could be applied to the wrong one.
        def recorded_by_company(companies, refusals)
          ids_by_name = companies.group_by { |_id, name| name }.transform_values { |rows| rows.map(&:first) }

          recorded_companies.each_with_object({}) do |(name, invoices), by_company|
            ids = ids_by_name.fetch(name, [])
            if ids.size == 1
              by_company[ids.first] = invoices.to_h
            else
              refusals[name] << "the recorded disposition names company #{name.inspect}, which matches #{ids.size} companies"
            end
          end
        end

        def legacy_entry(row)
          entry_row = row.except("join_company_id").merge(ENUM_COLUMNS.to_h { |column, names| [column, enum_name(names, column, row)] })
          {
            id: row["id"], locked: row["locked"] == true, company_id: row["company_id"],
            join_company_id: row["join_company_id"], row: entry_row
          }
        end

        def enum_name(names, column, row)
          names.key(row[column]) ||
            raise(Checkpoint::ShapeError, "entries: entry #{row['id']} has unknown #{column} #{row[column].inspect}")
        end

        def read_links(invoices)
          draft = Invoice.statuses.fetch("draft")
          facts = invoices.to_h do |id, company_id, _number, status, discarded_at|
            [id, { invoice_company_id: company_id, draft: status == draft, discarded: !discarded_at.nil? }]
          end

          cast_rows(LINKS_SQL).map do |invoice_id, entry_id|
            { entry_id:, invoice_id:, **facts.fetch(invoice_id) }
          end
        end

        def cast_rows(sql)
          connection.select_all(sql).cast_values
        end

        def read_audits
          changes_type = Audited::Audit.type_for_attribute("audited_changes")

          RowReader.select_rows(connection, AUDITS_SQL).map do |row|
            row.symbolize_keys.merge(audited_changes: changes_type.deserialize(row["audited_changes"]))
          end
        end
    end
  end
end

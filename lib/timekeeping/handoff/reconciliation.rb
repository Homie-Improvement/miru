# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The reconciliation of docs/architecture/timekeeping-soa.md section 10.4:
    # compares the loaded checkpoint with the frozen source, check by check and
    # company by company, and lists every difference. It never repairs one.
    # A difference aborts the handoff unless the pre-flight listed it for the
    # same company, check, row and field.
    #
    # run is pure: it reads plain hashes and snapshots, touches no database
    # and changes no input.
    class Reconciliation
      # One difference. row_key holds the identity values of the row and field
      # names the column, or is nil for a whole row. Row values are left out,
      # so neither the report nor a signal built from it carries notes or money.
      Difference = Data.define(:company_id, :check, :table, :row_key, :field, :reason) do
        def to_report
          {
            "company_id" => company_id,
            "check" => check.to_s,
            "table" => table,
            "row_key" => row_key.map { |value| value.is_a?(Symbol) ? value.to_s : value },
            "field" => field&.to_s,
            "reason" => reason.to_s
          }
        end
      end

      # A difference the pre-flight expects for one company. It explains only
      # the difference with the same check, row and field, so a second change
      # on the same row still aborts.
      Correction = Data.define(:check, :row_key, :field) do
        def explains?(difference)
          check == difference.check && row_key == difference.row_key && field&.to_s == difference.field&.to_s
        end
      end

      # One company's checks. Every check is present, with an empty list when
      # it found nothing, so the report shows that the check ran.
      CompanyReport = Data.define(:company_id, :checks, :listed, :unlisted) do
        def abort?
          unlisted.any?
        end

        def to_report
          {
            "company_id" => company_id,
            "abort" => abort?,
            "checks" => checks.to_h { |check, differences| [check.to_s, differences.map(&:to_report)] },
            "listed" => listed.map(&:to_report),
            "unlisted" => unlisted.map(&:to_report)
          }
        end
      end

      # unassigned holds projection rows that no single company claims. They
      # belong to no company report, and any of them aborts the handoff.
      Result = Data.define(:companies, :unassigned) do
        def abort?
          unassigned.any? || companies.each_value.any?(&:abort?)
        end

        # The plain form the handoff runner writes to a file.
        def to_h
          {
            "abort" => abort?,
            "companies" => companies.transform_values(&:to_report),
            "unassigned" => unassigned.map(&:to_report)
          }
        end
      end

      # The inputs of one run, grouped by company once so each check reads
      # only the rows of the company it checks.
      Inputs = Data.define(
        :source, :checkpoint, :source_digest, :checkpoint_digest, :projection, :source_intents, :intents,
        :next_entry_id, :money_before, :money_after, :expected_reservations
      ) do
        def rows(side, table, company_id)
          public_send(side).fetch(table).fetch(company_id, [])
        end

        def intent_rows(side, company_id)
          public_send(side).fetch(company_id, [])
        end
      end

      # The check each name runs, in report order. Each takes the inputs and a
      # company_id and returns that company's differences.
      CHECKS = {
        entries: :check_entries,
        totals: :check_totals,
        reservations: :check_reservations,
        reservation_classification: :check_reservation_classification,
        projection: :check_projection,
        audit_rows: :check_audit_rows,
        operation_receipts: :check_operation_receipts,
        idempotency_receipts: :check_idempotency_receipts,
        id_sequence: :check_id_sequence,
        money: :check_money
      }.freeze

      # The columns of a monolith invoice_operation_intents row. Intents are
      # not checkpoint rows, so they have their own shape here.
      INTENT_COLUMNS = %w[company_id invoice_id operation_id generation state created_at finished_at].freeze

      # The columns of a timesheet_entries row, which are the checkpoint
      # entry's columns.
      PROJECTION_COLUMNS = Checkpoint::TABLES.fetch("entries")

      # The reservation fields the pre-flight's classification decides.
      CLASSIFIED_COLUMNS = %w[invoice_id disposition].freeze

      ENTRY_KEY = ->(row) { [row["id"]] }
      RESERVATION_KEY = ->(row) { [row["entry_id"], row["state"]] }
      OPERATION_KEY = ->(row) { [row["operation_id"]] }

      # What an intent's state requires of the operations with its
      # operation_id: the reason it breaks the rule, or nil when it holds.
      INTENT_RULES = {
        "pending" => ->(_operation_states) { :intent_pending },
        "committed" => lambda do |operation_states|
          operation_states.include?("committed") ? nil : :intent_without_committed_operation
        end,
        "failed" => lambda do |operation_states|
          operation_states.all?("aborted") ? nil : :failed_intent_with_unaborted_operation
        end
      }.freeze

      MONEY_TABLE = "financial_snapshot"

      class << self
        # source, checkpoint: Checkpoint, the frozen source and the loaded copy.
        # projection: timesheet_entries rows, as stored (integer enums).
        # source_intents, intents: the monolith's invoice_operation_intents
        # rows read with the frozen source and after the handoff.
        # next_entry_id: the next id the incoming owner's sequence hands out.
        # money_before, money_after: { company_id => FinancialSnapshot }.
        # listed_corrections: { company_id => [Correction] }.
        # expected_reservations: on the first cutover only,
        # { company_id => [reservation rows] } from the pre-flight.
        #
        # Raises Checkpoint::ShapeError or ArgumentError for input the checks
        # cannot fully read, rather than reporting it as a pass.
        def run(source:, checkpoint:, projection:, source_intents:, intents:, next_entry_id:, money_before:,
                money_after:, listed_corrections: {}, expected_reservations: nil)
          check_inputs!(
            projection:, source_intents:, intents:, next_entry_id:, money_before:, money_after:, expected_reservations:
          )
          projection_by_company, unassigned = place_projection(projection, checkpoint.rows.fetch("entries"))

          inputs = Inputs.new(
            source: group_tables(source.rows),
            checkpoint: group_tables(checkpoint.rows),
            source_digest: Checkpoint.build(tables: source.rows).digest,
            checkpoint_digest: Checkpoint.build(tables: checkpoint.rows).digest,
            projection: projection_by_company,
            source_intents: source_intents.group_by { |row| row["company_id"] },
            intents: intents.group_by { |row| row["company_id"] },
            next_entry_id:, money_before:, money_after:, expected_reservations:
          )

          company_ids = [
            *[source.rows, checkpoint.rows].flat_map { |tables| tables.values.flatten },
            *projection, *source_intents, *intents
          ].pluck("company_id")
          company_ids += [money_before, money_after, listed_corrections, expected_reservations || {}].flat_map(&:keys)

          companies = company_ids.compact.uniq.sort.index_with do |company_id|
            company_report(inputs, company_id, listed_corrections.fetch(company_id, []))
          end
          Result.new(companies: companies.freeze, unassigned: unassigned.freeze)
        end

        # Emits one ReconciliationDifferenceFound per difference of a finished
        # result, listed ones included, and passes the identifiers of each
        # company's changed money values (kind, record id and field, without
        # the values) to FinancialSnapshot.report so the financial change
        # signal fires as well. Returns the result unchanged. It runs after run has
        # decided the verdict, so a signal that fails cannot alter the verdict.
        def report(result)
          result.companies.each_value do |company_report|
            company_report.listed.each { |difference| notify_difference(difference, listed: true) }
            company_report.unlisted.each { |difference| notify_difference(difference, listed: false) }
            FinancialSnapshot.report(financial_changes(company_report))
          end
          result.unassigned.each { |difference| notify_difference(difference, listed: false) }
          result
        end

        private

          def notify_difference(difference, listed:)
            Rails.event.notify(ReconciliationDifferenceFound.new(difference, listed:))
          end

          # Rebuilds the FinancialSnapshot::Difference that FinancialSnapshotChanged
          # reads from the stored identifiers. The money values are not kept in a
          # result, and the event never reads them, so they stay nil. A missing
          # snapshot names no invoice row, so it has no financial change to send.
          def financial_changes(company_report)
            company_report.checks.fetch(:money).filter_map do |difference|
              next unless difference.reason == :changed

              kind, record_id = difference.row_key
              FinancialSnapshot::Difference.new(
                company_id: difference.company_id, kind:, record_id:, field: difference.field,
                old_value: nil, new_value: nil
              )
            end
          end

          def company_report(inputs, company_id, corrections)
            checks = CHECKS.to_h { |check, method| [check, send(method, inputs, company_id).freeze] }.freeze
            listed, unlisted = checks.values.flatten.partition do |difference|
              corrections.any? { |correction| correction.explains?(difference) }
            end
            CompanyReport.new(company_id:, checks:, listed: listed.freeze, unlisted: unlisted.freeze)
          end

          def check_inputs!(projection:, source_intents:, intents:, next_entry_id:, money_before:, money_after:,
                            expected_reservations:)
            check_columns!("projection", projection, PROJECTION_COLUMNS)
            check_columns!("source_intents", source_intents, INTENT_COLUMNS)
            check_columns!("intents", intents, INTENT_COLUMNS)
            [source_intents, intents].flatten.each do |row|
              raise Checkpoint::ShapeError, "intents: a row has no company_id" unless row["company_id"].is_a?(Integer)
            end
            raise ArgumentError, "next_entry_id must be an Integer" unless next_entry_id.is_a?(Integer)

            # A snapshot filed under another company would be compared as the
            # wrong company's money.
            [money_before, money_after].each do |snapshots|
              snapshots.each do |company_id, snapshot|
                next if snapshot.fetch(:company_id) == company_id

                raise ArgumentError, "the financial snapshot filed under company #{company_id} is another company's"
              end
            end

            # A classification row filed under another company would certify
            # that company's reservations. Rows without a company_id are taken
            # as the company they are filed under.
            (expected_reservations || {}).each do |company_id, rows|
              rows.each do |row|
                next if !row.key?("company_id") || row["company_id"] == company_id

                raise ArgumentError, "an expected reservation filed under company #{company_id} is another company's"
              end
            end
          end

          def check_columns!(name, rows, columns)
            rows.each do |row|
              unknown = row.keys - columns
              missing = columns - row.keys
              raise Checkpoint::ShapeError, "#{name}: unknown columns: #{unknown.join(', ')}" if unknown.any?
              raise Checkpoint::ShapeError, "#{name}: missing columns: #{missing.join(', ')}" if missing.any?
            end
          end

          def group_tables(tables)
            tables.transform_values { |rows| rows.group_by { |row| row["company_id"] } }
          end

          # Places each projection row under a company. A row whose company_id
          # and id match a checkpoint entry goes to that company. A row whose
          # company_id is nil or matches no such entry goes to the one company
          # whose checkpoint entry has its id, where its company_id then shows
          # as a difference. A row whose id no checkpoint entry has stays under
          # its own company_id, where it shows as missing from the checkpoint.
          # A row that no single company claims, or that has no entry and no
          # company_id, is unassigned, so it is neither dropped nor filed under
          # a guessed company.
          #
          # Returns [{ company_id => [normalised rows] }, [unassigned Difference]].
          def place_projection(projection, checkpoint_entries)
            entry_keys = checkpoint_entries.to_set { |row| [row["company_id"], row["id"]] }
            companies_by_id = checkpoint_entries.group_by { |row| row["id"] }
              .transform_values { |rows| rows.map { |row| row["company_id"] }.uniq }

            placed = projection.group_by do |row|
              next row["company_id"] if entry_keys.include?([row["company_id"], row["id"]])

              candidates = companies_by_id.fetch(row["id"], [])
              next row["company_id"] if candidates.empty?

              candidates.one? ? candidates.first : nil
            end

            unassigned = placed.fetch(nil, []).map do |row|
              Difference.new(
                company_id: nil, check: :projection, table: "timesheet_entries", row_key: ENTRY_KEY.call(row),
                field: nil, reason: :no_company_claims_row
              )
            end
            by_company = placed.except(nil).transform_values { |rows| rows.map { |row| normalise_projection_row(row) } }
            [by_company, unassigned]
          end

          # timesheet_entries stores bill_status and review_status as integer
          # enums; the checkpoint holds their names. Builds a new row, so the
          # caller's row stays as it was read.
          def normalise_projection_row(row)
            row.merge(
              "bill_status" => enum_name(TimesheetEntry.bill_statuses, row["bill_status"]),
              "review_status" => enum_name(TimesheetEntry.review_statuses, row["review_status"])
            )
          end

          def enum_name(mapping, value)
            value.is_a?(Integer) ? mapping.key(value) || value : value
          end

          def check_entries(inputs, company_id)
            compare_rows(
              company_id:, check: :entries, table: "entries", key: ENTRY_KEY,
              expected: inputs.rows(:source, "entries", company_id),
              actual: inputs.rows(:checkpoint, "entries", company_id),
              encode: encoder("entries")
            )
          end

          def check_totals(inputs, company_id)
            expected = duration_totals(inputs.rows(:source, "entries", company_id))
            actual = duration_totals(inputs.rows(:checkpoint, "entries", company_id))

            (expected.keys | actual.keys).flat_map do |row_key|
              difference = ->(field, reason) { Difference.new(company_id:, check: :totals, table: "entries", row_key:, field:, reason:) }
              next [difference.call(nil, :missing_in_checkpoint)] unless actual.key?(row_key)
              next [difference.call(nil, :missing_in_source)] unless expected.key?(row_key)

              expected.fetch(row_key).keys
                .reject { |field| expected.fetch(row_key)[field] == actual.fetch(row_key)[field] }
                .map { |field| difference.call(field, :changed) }
            end
          end

          # The company-wide total under row key [], then one total per user and
          # month. Durations are added in ascending entry id order on both sides,
          # because float addition depends on order, and sums compare by their bits.
          def duration_totals(entries)
            ordered = entries.sort_by { |row| row["id"] }
            per_user_month = ordered.group_by { |row| [row["user_id"], row["work_date"].strftime("%Y-%m")] }
            { [] => duration_total(ordered) }.merge(per_user_month.transform_values { |rows| duration_total(rows) })
          end

          def duration_total(rows)
            sum = rows.inject(0.0) { |total, row| total + row["duration"] }
            { "count" => rows.size, "duration_sum" => float_bits(sum) }
          end

          def float_bits(value)
            [value.to_f].pack("G").unpack1("H*")
          end

          def check_reservations(inputs, company_id)
            loaded = inputs.rows(:checkpoint, "reservations", company_id)
            provisional = loaded.filter_map do |row|
              next unless row["state"] == "provisional"

              Difference.new(
                company_id:, check: :reservations, table: "reservations", row_key: RESERVATION_KEY.call(row),
                field: "state", reason: :provisional_remains
              )
            end

            # A second committed reservation for one entry repeats its key, so
            # compare_rows reports it as a duplicate.
            compare_rows(
              company_id:, check: :reservations, table: "reservations", key: RESERVATION_KEY,
              expected: inputs.rows(:source, "reservations", company_id), actual: loaded,
              encode: encoder("reservations")
            ) + provisional
          end

          def check_reservation_classification(inputs, company_id)
            return [] if inputs.expected_reservations.nil?

            compare_rows(
              company_id:, check: :reservation_classification, table: "reservations", key: RESERVATION_KEY,
              expected: inputs.expected_reservations.fetch(company_id, []),
              actual: inputs.rows(:checkpoint, "reservations", company_id),
              encode: ->(row) { CLASSIFIED_COLUMNS.index_with { |column| row.fetch(column) } }
            )
          end

          # Compares every column but locked with the checkpoint entry. locked
          # must instead say whether the entry has a committed reservation.
          def check_projection(inputs, company_id)
            entries = inputs.rows(:checkpoint, "entries", company_id)
            projected = inputs.projection.fetch(company_id, [])
            reserved_ids = inputs.rows(:checkpoint, "reservations", company_id)
              .select { |row| row["state"] == "committed" }.to_set { |row| row["entry_id"] }

            field_differences = compare_rows(
              company_id:, check: :projection, table: "timesheet_entries", key: ENTRY_KEY,
              expected: entries, actual: projected,
              encode: ->(row) { encoder("entries").call(row).except("locked") },
              missing: %i[missing_in_projection missing_in_checkpoint]
            )

            rows_by_id = projected.group_by { |row| row["id"] }
            locked_differences = entries.filter_map do |entry|
              rows = rows_by_id.fetch(entry["id"], [])
              next unless rows.one?
              next if rows.first["locked"] == reserved_ids.include?(entry["id"])

              Difference.new(
                company_id:, check: :projection, table: "timesheet_entries", row_key: ENTRY_KEY.call(entry),
                field: "locked", reason: :locked_disagrees_with_reservation
              )
            end

            field_differences + locked_differences
          end

          def check_audit_rows(inputs, company_id)
            compare_digests(inputs, company_id, :audit_rows, "entry_audits")
          end

          def check_idempotency_receipts(inputs, company_id)
            compare_digests(inputs, company_id, :idempotency_receipts, "idempotency_records")
          end

          def compare_digests(inputs, company_id, check, table)
            expected = inputs.source_digest.fetch(table)[company_id]
            actual = inputs.checkpoint_digest.fetch(table)[company_id]

            %i[count checksum].filter_map do |field|
              next if expected&.fetch(field) == actual&.fetch(field)

              Difference.new(company_id:, check:, table:, row_key: [], field: field.to_s, reason: :changed)
            end
          end

          def check_operation_receipts(inputs, company_id)
            operations = inputs.rows(:checkpoint, "invoice_operations", company_id)
            current_intents = inputs.intent_rows(:intents, company_id)
            operation_states = operations.group_by { |row| row["operation_id"] }
              .transform_values { |rows| rows.map { |row| row["state"] } }

            prepared = operations.filter_map do |row|
              next unless row["state"] == "prepared"

              Difference.new(
                company_id:, check: :operation_receipts, table: "invoice_operations", row_key: OPERATION_KEY.call(row),
                field: "state", reason: :operation_prepared
              )
            end
            intent_breaches = current_intents.filter_map do |intent|
              reason = INTENT_RULES.fetch(intent["state"]).call(operation_states.fetch(intent["operation_id"], []))
              next unless reason

              Difference.new(
                company_id:, check: :operation_receipts, table: "invoice_operation_intents",
                row_key: OPERATION_KEY.call(intent), field: "state", reason:
              )
            end

            compare_rows(
              company_id:, check: :operation_receipts, table: "invoice_operations", key: OPERATION_KEY,
              expected: inputs.rows(:source, "invoice_operations", company_id), actual: operations,
              encode: encoder("invoice_operations")
            ) + compare_rows(
              company_id:, check: :operation_receipts, table: "invoice_operation_intents", key: OPERATION_KEY,
              expected: inputs.intent_rows(:source_intents, company_id), actual: current_intents,
              encode: ->(row) { row.slice(*INTENT_COLUMNS) }
            ) + prepared + intent_breaches
          end

          # The incoming owner's sequence is one number for every company. It is
          # higher than the highest checkpoint id exactly when it is higher than
          # each company's highest id, so each company reports only its own.
          def check_id_sequence(inputs, company_id)
            highest = inputs.rows(:checkpoint, "entries", company_id).pluck("id").max
            return [] if highest.nil? || inputs.next_entry_id > highest

            [
              Difference.new(
                company_id:, check: :id_sequence, table: "entries", row_key: [highest], field: "id",
                reason: :sequence_not_higher
              )
            ]
          end

          # A company with no snapshot on a side has unproven money, so the
          # missing side is a difference rather than an empty comparison.
          def check_money(inputs, company_id)
            snapshots = { before: inputs.money_before[company_id], after: inputs.money_after[company_id] }
            missing = snapshots.select { |_side, snapshot| snapshot.nil? }.keys.map do |side|
              Difference.new(
                company_id:, check: :money, table: MONEY_TABLE, row_key: [], field: side, reason: :snapshot_missing
              )
            end
            return missing if missing.any?

            FinancialSnapshot.compare(snapshots.fetch(:before), snapshots.fetch(:after)).map do |change|
              Difference.new(
                company_id:, check: :money, table: MONEY_TABLE, row_key: [change.kind, change.record_id],
                field: change.field, reason: :changed
              )
            end
          end

          # Compares one company's rows on two sides by key. It walks the keys of
          # both sides, so a row on one side only is reported, and it reports a
          # key that appears twice on a side instead of keeping one of the rows.
          # missing names the reason for a key absent from actual, then from expected.
          def compare_rows(company_id:, check:, table:, key:, expected:, actual:, encode:,
                           missing: %i[missing_in_checkpoint missing_in_source])
            expected_rows = expected.group_by(&key)
            actual_rows = actual.group_by(&key)

            (expected_rows.keys | actual_rows.keys).flat_map do |row_key|
              difference = ->(field, reason) { Difference.new(company_id:, check:, table:, row_key:, field:, reason:) }
              old_rows = expected_rows.fetch(row_key, [])
              new_rows = actual_rows.fetch(row_key, [])
              next [difference.call(nil, missing.first)] if new_rows.empty?
              next [difference.call(nil, missing.last)] if old_rows.empty?
              next [difference.call(nil, :duplicate_key)] if old_rows.size > 1 || new_rows.size > 1

              old_values = encode.call(old_rows.first)
              new_values = encode.call(new_rows.first)
              (old_values.keys | new_values.keys)
                .reject { |field| old_values[field] == new_values[field] }
                .map { |field| difference.call(field, :changed) }
            end
          end

          # Checkpoint.encode_row tags every value with its type and encodes a
          # float by its IEEE-754 bits, so 0.0 and -0.0 differ.
          def encoder(table)
            ->(row) { Checkpoint.encode_row(table, row).to_h }
          end
      end
    end
  end
end

# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "json"
require "time"

module Timekeeping
  module Handoff
    # The checkpoint of docs/architecture/timekeeping-soa.md section 10.3: the
    # rows that move time-entry data between the monolith and Timekeeping, with
    # a row count and a checksum per table and per company.
    #
    # TABLES and the value encoding below are the one definition of a
    # checkpoint's row shape and checksum. A store returns rows in that shape
    # and the checkpoint computes every count and checksum from them.
    #
    # Pure: it reads plain hashes and touches no database.
    class Checkpoint
      # A row that does not fit its table's canonical shape. Raised instead of
      # dropping, defaulting or converting the value, so nothing is lost.
      class ShapeError < StandardError; end

      # Each table's canonical columns, in encoding order. The columns of
      # entry_audits and idempotency_records equal Timekeeping's audit_events
      # and idempotency_receipts, so a row loads into either application.
      # service_idempotency_receipts holds the stored answers of commit,
      # abort, mark_billed and detach_entries under the same name in both
      # applications. It crosses a cutover so a service command retried on
      # the other side replays its answer instead of running again.
      TABLES = {
        "entries" => %w[
          id company_id version project_id user_id agent_id work_date duration note bill_status
          review_status locked source source_metadata external_run_id external_session_id proof_url
          proof_metadata discarded_at created_at updated_at
        ],
        "reservations" => %w[
          company_id entry_id invoice_id state disposition operation_id created_at invoice_operation_id
        ],
        "invoice_operations" => %w[
          id company_id invoice_id operation_id actor_name state desired_entry_ids disposition generation
          created_at finished_at
        ],
        "entry_audits" => %w[
          id company_id entry_id actor_type actor_id actor_name action before after entry_created_at created_at
        ],
        "idempotency_records" => %w[
          id company_id actor_type actor_id operation key fingerprint status body created_at
        ],
        "service_idempotency_receipts" => %w[
          id company_id actor_name operation key fingerprint status body created_at
        ]
      }.transform_values(&:freeze).freeze

      # Nanoseconds, so a Ruby time survives transport exactly. Postgres keeps
      # microseconds, so a finer time read back from it no longer matches.
      TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%9NZ"

      # A jsonb cell holding the JSON value null. Ruby nil stands for SQL NULL,
      # so a nullable jsonb column such as entry_audits.before needs a second
      # value to keep the two apart.
      JSON_NULL = Object.new.tap { |value| def value.inspect = "Timekeeping::Handoff::Checkpoint::JSON_NULL" }.freeze

      attr_reader :rows, :digest

      class << self
        # tables: { table name => [row hash with string keys] }, every table in TABLES.
        def build(tables:)
          check_shape!(tables)
          new(rows: tables, digest: digest_of(tables))
        end

        # Recomputes every count and checksum from the rows and compares them
        # with the checkpoint's digest. A company that appears on only one side
        # is a mismatch too, so rows that vanished are reported.
        #
        # Returns [{ table:, company_id:, expected:, actual: }], empty when all match.
        # Raises ShapeError for rows outside the canonical shape, since the
        # checksum reads only canonical columns and would not see the rest.
        def verify(checkpoint)
          check_shape!(checkpoint.rows)
          actual_digest = digest_of(checkpoint.rows)

          (TABLES.keys | checkpoint.digest.keys).flat_map do |table|
            expected = checkpoint.digest.fetch(table, {})
            actual = actual_digest.fetch(table, {})

            (expected.keys | actual.keys).sort.filter_map do |company_id|
              next if expected[company_id] == actual[company_id]

              { table:, company_id:, expected: expected[company_id], actual: actual[company_id] }
            end
          end
        end

        # Reads the transport form written by #to_json. The digest is taken as
        # written, not recomputed, so verify can tell whether the rows still match it.
        def from_json(json)
          document = JSON.parse(json)
          tables = document.fetch("tables").to_h do |table, encoded_rows|
            [table, encoded_rows.map { |encoded_row| decode_row(table, encoded_row) }]
          end
          check_shape!(tables)
          new(rows: tables, digest: parse_digest(document.fetch("digest")))
        end

        # The [column, tagged value] pairs of a row, in canonical column order.
        # Used for both the checksum and the transport form.
        def encode_row(table, row)
          TABLES.fetch(table).map do |column|
            [column, encode_value(row.fetch(column))]
          rescue ShapeError => error
            raise ShapeError, "#{table}.#{column}: #{error.message}"
          end
        end

        # Raises ShapeError, naming the table, for a missing or unknown table,
        # a column with no home, a missing column or a row without company_id.
        # Every path that reads rows calls it first, because encoding reads
        # only canonical columns and would silently skip the rest.
        def check_shape!(tables)
          missing = TABLES.keys - tables.keys
          unknown = tables.keys - TABLES.keys
          raise ShapeError, "missing tables: #{missing.join(', ')}" if missing.any?
          raise ShapeError, "unknown tables: #{unknown.join(', ')}" if unknown.any?

          tables.each { |table, rows| rows.each { |row| check_row!(table, row) } }
        end

        private

          def check_row!(table, row)
            columns = TABLES.fetch(table)
            unknown = row.keys - columns
            missing = columns - row.keys
            raise ShapeError, "#{table}: columns with no home in the checkpoint: #{unknown.join(', ')}" if unknown.any?
            raise ShapeError, "#{table}: missing columns: #{missing.join(', ')}" if missing.any?
            raise ShapeError, "#{table}: a row has no company_id" unless row["company_id"].is_a?(Integer)

            encode_row(table, row)
          end

          # { table => { company_id => { count:, checksum: } } }; a table with no
          # rows has an empty hash.
          def digest_of(tables)
            TABLES.keys.index_with do |table|
              tables.fetch(table, []).group_by { |row| row["company_id"] }.transform_values do |rows|
                { count: rows.size, checksum: checksum(table, rows) }
              end
            end
          end

          # Sorted row digests make the checksum independent of the order a
          # store returns its rows in.
          def checksum(table, rows)
            row_digests = rows.map { |row| Digest::SHA256.hexdigest(JSON.generate(encode_row(table, row))) }
            Digest::SHA256.hexdigest(row_digests.sort.join("\n"))
          end

          # Every value carries its type, so nil differs from "", 1 from 1.0 and
          # a float is compared by its IEEE-754 bits, not a printed decimal.
          def encode_value(value)
            case value
            when nil then ["nil"]
            when true, false then ["bool", value]
            when Integer then ["int", value.to_s]
            when Float then ["float", [value].pack("G").unpack1("H*")]
            when BigDecimal then ["decimal", value.to_s]
            when String then ["str", value]
            when ActiveSupport::TimeWithZone, Time, DateTime then ["time", value.to_time.getutc.strftime(TIME_FORMAT)]
            when Date then ["date", value.iso8601]
            when Array then ["array", value.map { |item| encode_json_value(item) }]
            when Hash then ["hash", encode_hash(value)]
            when JSON_NULL then ["json_null"]
            else raise ShapeError, "unsupported value type #{value.class}"
            end
          end

          # jsonb ignores key order, so keys are sorted.
          def encode_hash(hash)
            raise ShapeError, "a JSON object key is not a string" unless hash.keys.all?(String)

            hash.sort_by(&:first).map { |key, item| [key, encode_json_value(item)] }
          end

          # Inside a JSON object or array a number is a decimal, however it was
          # read: a Float and a BigDecimal of the same decimal value encode the
          # same, so a store that reads jsonb decimals exactly matches rows
          # built from Floats. Only bigint[] and jsonb hold arrays, and bigint[]
          # holds no Floats. A Float column value, such as duration, keeps its
          # bit encoding in encode_value.
          def encode_json_value(value)
            value.is_a?(Float) ? ["decimal", BigDecimal(value.to_s).to_s] : encode_value(value)
          end

          def decode_row(table, encoded_row)
            encoded_row.to_h { |column, tagged| [column, decode_value(tagged)] }
          rescue ShapeError, ArgumentError, TypeError, NoMethodError => error
            raise ShapeError, "#{table}: unreadable row: #{error.message}"
          end

          def decode_value(tagged)
            tag, payload = tagged
            case tag
            when "nil" then nil
            when "json_null" then JSON_NULL
            when "bool" then payload
            when "int" then Integer(payload, 10)
            when "float" then [payload].pack("H*").unpack1("G")
            when "decimal" then BigDecimal(payload)
            when "str" then payload
            when "time" then Time.iso8601(payload).utc
            when "date" then Date.iso8601(payload)
            when "array" then payload.map { |item| decode_value(item) }
            when "hash" then payload.to_h { |key, item| [key, decode_value(item)] }
            else raise ShapeError, "unknown value tag #{tag.inspect}"
            end
          end

          def parse_digest(document)
            document.to_h do |table, companies|
              [table, companies.to_h do |company_id, entry|
                [Integer(company_id, 10), { count: entry.fetch("count"), checksum: entry.fetch("checksum") }]
              end]
            end
          end
      end

      # Rows are copied and frozen, so a field added after construction
      # cannot slip past the shape checks into a load or the transport form.
      def initialize(rows:, digest:)
        @rows = rows.to_h { |table, table_rows| [table, table_rows.map { |row| row.dup.freeze }.freeze] }.freeze
        @digest = digest
      end

      # The transport form: every row as its encoded [column, tagged value]
      # pairs, and the digest with company ids as JSON object keys.
      def to_json(*)
        self.class.check_shape!(rows)
        JSON.generate(
          "tables" => rows.to_h { |table, table_rows| [table, table_rows.map { |row| self.class.encode_row(table, row) }] },
          "digest" => digest.transform_values do |companies|
            companies.to_h { |company_id, entry| [company_id.to_s, { "count" => entry[:count], "checksum" => entry[:checksum] }] }
          end
        )
      end
    end
  end
end

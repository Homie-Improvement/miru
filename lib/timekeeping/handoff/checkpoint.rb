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
      TABLES = {
        "entries" => %w[
          id company_id version project_id user_id agent_id work_date duration note bill_status
          review_status locked source source_metadata external_run_id external_session_id proof_url
          proof_metadata discarded_at created_at updated_at
        ],
        "reservations" => %w[company_id entry_id invoice_id state disposition operation_id created_at],
        "invoice_operations" => %w[
          id company_id invoice_id operation_id state desired_entry_ids disposition generation
          created_at finished_at
        ],
        "entry_audits" => %w[
          id company_id entry_id actor_type actor_id action before after entry_created_at created_at
        ],
        "idempotency_records" => %w[
          id company_id actor_type actor_id operation key fingerprint status body created_at
        ]
      }.transform_values(&:freeze).freeze

      # Nanoseconds, so a Ruby time survives transport exactly. Postgres keeps
      # microseconds, so a finer time read back from it no longer matches.
      TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%9NZ"

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
        def verify(checkpoint)
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

        private

          def check_shape!(tables)
            missing = TABLES.keys - tables.keys
            unknown = tables.keys - TABLES.keys
            raise ShapeError, "missing tables: #{missing.join(', ')}" if missing.any?
            raise ShapeError, "unknown tables: #{unknown.join(', ')}" if unknown.any?

            tables.each { |table, rows| rows.each { |row| check_row!(table, row) } }
          end

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
            when String then ["str", value]
            when ActiveSupport::TimeWithZone, Time, DateTime then ["time", value.to_time.getutc.strftime(TIME_FORMAT)]
            when Date then ["date", value.iso8601]
            when Array then ["array", value.map { |item| encode_value(item) }]
            when Hash then ["hash", encode_hash(value)]
            else raise ShapeError, "unsupported value type #{value.class}"
            end
          end

          # jsonb ignores key order, so keys are sorted.
          def encode_hash(hash)
            raise ShapeError, "a JSON object key is not a string" unless hash.keys.all?(String)

            hash.sort_by(&:first).map { |key, item| [key, encode_json_value(item)] }
          end

          # A JSON number is a decimal, however it was read: a Float and a
          # BigDecimal of the same decimal value encode the same, so a store
          # that reads jsonb decimals exactly matches rows built from Floats.
          def encode_json_value(value)
            case value
            when Float then ["decimal", BigDecimal(value.to_s).to_s]
            when BigDecimal then ["decimal", value.to_s]
            when Array then ["array", value.map { |item| encode_json_value(item) }]
            else encode_value(value)
            end
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

      def initialize(rows:, digest:)
        @rows = rows
        @digest = digest
      end

      # The transport form: every row as its encoded [column, tagged value]
      # pairs, and the digest with company ids as JSON object keys.
      def to_json(*)
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

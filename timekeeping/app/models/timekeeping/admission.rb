# frozen_string_literal: true

module Timekeeping
  # The one generation Timekeeping admits entry writes at, or none (a null
  # generation) while fenced (docs/architecture/timekeeping-soa.md sections
  # 10.1 and 10.5). It is global, not per company. The database allows only the
  # row with id 1, and its column default holds the initial generation, 1.
  # No method here creates the row on demand: a missing row refuses every
  # write instead of silently admitting generation 1.
  class Admission < ApplicationRecord
    self.table_name = "admission"

    SINGLETON_ID = 1
    # How long a fence waits for writes already admitted before it gives up.
    FENCE_LOCK_TIMEOUT = 60.seconds

    # Raises ActiveRecord::RecordNotFound when the row is missing, so a caller
    # never mistakes lost admission state for a fresh start.
    def self.current
      find(SINGLETON_ID)
    end

    # Creates the initial row from the column defaults when the table is empty,
    # and leaves an existing row, fenced or not, unchanged. A database loaded
    # from db/schema.rb has no rows, so db/seeds.rb and the test suite call
    # this; the migration inserts the row on databases that migrate.
    def self.ensure_initial!
      insert_all([{ id: SINGLETON_ID }], unique_by: :id)
    end

    # The admitted generation, read FOR SHARE so a fence waits for the calling
    # transaction to commit. nil when fenced or when the row is missing.
    def self.locked_generation
      connection.select_value(sanitize_sql_array(["SELECT generation FROM admission WHERE id = ? FOR SHARE",
                                                  SINGLETON_ID]))
    end

    # Admits no generation. The UPDATE waits for writes holding the row FOR
    # SHARE, for at most lock_timeout; past it ActiveRecord::LockWaitTimeout is
    # raised and the generation is left as it was. SET LOCAL ends with the
    # transaction, so the timeout never stays on a pooled connection.
    def self.fence!(lock_timeout: FENCE_LOCK_TIMEOUT)
      transaction do
        connection.execute("SET LOCAL lock_timeout = '#{Integer(lock_timeout.in_milliseconds)}ms'")
        set_generation(nil)
      end
    end

    # Admits writes at generation only. Only a positive Integer can ever match
    # an Ownership-Generation header, and a nil here would fence unannounced,
    # so anything else is refused before the row is touched.
    def self.admit!(generation:)
      raise ArgumentError, "generation must be a positive Integer" unless generation.is_a?(Integer) && generation.positive?

      transaction { set_generation(generation) }
    end

    def self.set_generation(generation)
      updated = where(id: SINGLETON_ID).update_all(generation:)
      raise ActiveRecord::RecordNotFound.new("admission row is missing", name, primary_key, SINGLETON_ID) if updated.zero?
    end
    private_class_method :set_generation
  end
end

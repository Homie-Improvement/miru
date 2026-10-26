# frozen_string_literal: true

module Timekeeping
  module Handoff
    # Writes the first cutover's correction snapshots
    # (docs/architecture/timekeeping-soa.md section 10.4): one outbox snapshot
    # per corrected entry, at the given version and generation. Writing the
    # same corrections again replaces them, so an entry never has a second
    # correction snapshot at one generation.
    #
    # A snapshot is an outbox row without version and generation, which come
    # from the call. Shape problems raise Checkpoint::ShapeError; a refusal
    # that depends on stored data raises Store::Error. Either way nothing is
    # written.
    module CorrectionSnapshots
      SNAPSHOT_FIELDS = (OutboxFields::ENTRY_FIELDS - ["version"]).freeze

      module_function

      # Returns the number of snapshots written.
      def write!(snapshots:, version:, generation:)
        check_shape!(snapshots, version:, generation:)
        keys = snapshots.map { |snapshot| snapshot.values_at("company_id", "id") }

        ApplicationRecord.transaction do
          FenceCheck.require_fenced!(ApplicationRecord.connection, "write correction snapshots")
          lock_entries!(keys)
          OutboxSnapshot.lock_for_insert!
          OutboxSnapshot.where([:company_id, :id] => keys, generation:).delete_all
          OutboxSnapshot.insert_all!(snapshots.map { |snapshot| snapshot.merge("version" => version, "generation" => generation) }) if snapshots.any?
          raise_stored_versions!(keys, version)
        end
        snapshots.size
      end

      # Two snapshots for one entry would both be inserted, and the projection
      # would apply only the first, so they are refused instead of picking one.
      def check_shape!(snapshots, version:, generation:)
        raise Checkpoint::ShapeError, "version must be a positive Integer" unless positive_integer?(version)
        raise Checkpoint::ShapeError, "generation must be a positive Integer" unless positive_integer?(generation)
        raise Checkpoint::ShapeError, "snapshots must be a list of objects" unless snapshots.is_a?(Array) && snapshots.all?(Hash)

        snapshots.each do |snapshot|
          unknown = snapshot.keys - SNAPSHOT_FIELDS
          missing = SNAPSHOT_FIELDS - snapshot.keys
          raise Checkpoint::ShapeError, "correction snapshot: unknown fields: #{unknown.join(', ')}" if unknown.any?
          raise Checkpoint::ShapeError, "correction snapshot: missing fields: #{missing.join(', ')}" if missing.any?
          unless positive_integer?(snapshot["company_id"]) && positive_integer?(snapshot["id"])
            raise Checkpoint::ShapeError, "correction snapshot: company_id and id must be positive Integers"
          end
        end

        duplicates = snapshots.map { |snapshot| snapshot.values_at("company_id", "id") }.tally.select { |_, count| count > 1 }
        return if duplicates.empty?

        raise Checkpoint::ShapeError,
          "correction snapshots name an entry more than once: #{duplicates.keys.map { |company_id, id| "company_id #{company_id} id #{id}" }.join(', ')}"
      end

      def positive_integer?(value)
        value.is_a?(Integer) && value.positive?
      end

      # Every corrected entry must be stored under the company the snapshot
      # names. Locking the rows also makes a concurrent write of the same
      # corrections wait for this one to commit.
      def lock_entries!(keys)
        found = Entry.where([:company_id, :id] => keys).lock.pluck(:company_id, :id)
        missing = keys - found
        return if missing.empty?

        companies = missing.map(&:first).uniq.sort
        raise Store::Error, "correction snapshots name entries that are not stored, for company_id #{companies.join(', ')}"
      end

      # EntryWriter gives an entry's next write the stored version plus one, and
      # the projection applies only a higher version than it holds. An entry
      # stored below the correction's version would make its first edit equal
      # to the correction, and that edit would be ignored. Raising, never
      # lowering, keeps a repeated correction from moving it again.
      def raise_stored_versions!(keys, version)
        Entry.where([:company_id, :id] => keys).where("version < ?", version).update_all(version:)
      end

      private_class_method :check_shape!, :positive_integer?, :lock_entries!, :raise_stored_versions!
    end
  end
end

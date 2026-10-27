# frozen_string_literal: true

module Timekeeping
  module Handoff
    # The copy of a legacy checkpoint the first cutover loads into Timekeeping.
    #
    # Timekeeping refuses a load whose entries are older than the ones it
    # stores, and writing a correction raises the corrected entry to the
    # correction version. Loading the legacy rows, still at version 0, after
    # corrections were written, on a resume or on a retry after an abort,
    # would therefore be refused. Each entry in the copy carries the highest of
    # its legacy version, the correction version when it is corrected, and the
    # version Timekeeping already stores, so versions only rise.
    #
    # Legacy entries default to version 0, but Timekeeping accepts only a
    # positive version in a checkpoint (its CheckpointEntryValues rule, the
    # projection's rule for version). So every entry is also raised to at
    # least LOWEST_LOADABLE_VERSION; reconciliation lists that raise like any
    # other.
    #
    # A corrected entry also carries its correction's `locked` value, so the
    # entry Timekeeping stores equals the correction snapshot it relays to the
    # monolith's projection, and a later rollback reconciles the two.
    #
    # Reading Timekeeping's stored versions is safe only while the source is
    # legacy: no handoff has admitted writes to Timekeeping yet, so its rows
    # came only from an earlier load of this same source.
    #
    # Pure: it reads checkpoints and correction lists and builds new ones.
    module LegacyLoadVersions
      LOWEST_LOADABLE_VERSION = 1

      module_function

      # source: the legacy Checkpoint. corrections: LegacySource's correction
      # list. stored: Timekeeping's current Checkpoint, or nil when it holds none.
      def build(source:, corrections:, stored:)
        corrected_locked = corrections.to_h { |correction| [correction.fetch("entry_id"), correction.dig("snapshot", "locked")] }
        stored_versions = stored ? stored.rows.fetch("entries").to_h { |row| [row["id"], row["version"]] } : {}

        entries = source.rows.fetch("entries").map do |row|
          floors = [LOWEST_LOADABLE_VERSION, stored_versions[row["id"]]]
          next with_version(row, floors.compact.max) unless corrected_locked.key?(row["id"])

          corrected = row.merge("locked" => corrected_locked.fetch(row["id"]))
          with_version(corrected, [ReservationDerivation::CORRECTION_VERSION, *floors].compact.max)
        end
        Checkpoint.build(tables: source.rows.merge("entries" => entries))
      end

      # The differences reconciliation must accept on the first cutover, by
      # company: each raised version, in the loaded entries and against the
      # projection, and each corrected locked value, in the loaded entries and
      # against the projection, which its snapshot reaches only after the flip.
      #
      # Returns { company_id => [Reconciliation::Correction] }.
      # Each correction is filed under the company its entry row names, the
      # company reconciliation reports that row under.
      def listed_corrections(source:, loaded:, corrections:)
        source_versions = source.rows.fetch("entries").to_h { |row| [row["id"], row["version"]] }
        company_of = loaded.rows.fetch("entries").to_h { |row| [row["id"], row["company_id"]] }
        raised = loaded.rows.fetch("entries").reject { |row| source_versions[row["id"]] == row["version"] }

        listed = raised.flat_map do |row|
          %i[entries projection].map do |check|
            [row["company_id"], Reconciliation::Correction.new(check:, row_key: [row["id"]], field: "version")]
          end
        end
        listed += corrections.flat_map do |correction|
          entry_id = correction.fetch("entry_id")
          %i[entries projection].map do |check|
            [company_of.fetch(entry_id, correction.fetch("company_id")),
             Reconciliation::Correction.new(check:, row_key: [entry_id], field: "locked")]
          end
        end
        listed.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      end

      # The row at the higher of its own version and the given one.
      def with_version(row, version)
        return row if version.nil? || version <= row["version"]

        row.merge("version" => version)
      end
      private_class_method :with_version
    end
  end
end

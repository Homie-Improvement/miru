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

    # What a reservation write reads under its share lock.
    LockedState = Data.define(:generation, :settling_generation)
    # What a settle step transition reads under the row lock.
    PhaseState = Data.define(:generation, :settling_generation, :settling_stopped_generation)

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

    # Admits writes at generation only, and ends any open settle step. A nil
    # here would fence unannounced, so check_generation! refuses it before the
    # row is touched. The stop mark is kept, so a late settle for a stopped
    # generation still cannot reopen its step.
    #
    # Admitting the held generation releases its correction snapshots to the
    # relay. Admitting any other generation means the handoff that wrote them
    # was abandoned, so its undelivered snapshots are removed: the projection
    # would refuse them, and one refused batch stops the relay.
    def self.admit!(generation:)
      check_generation!(generation)

      transaction do
        set_generation(generation)
        where(id: SINGLETON_ID).update_all(settling_generation: nil)
        held = where(id: SINGLETON_ID).pick(:held_generation)
        next if held.nil?

        OutboxSnapshot.where(generation: held, sent_at: nil).delete_all unless held == generation
        where(id: SINGLETON_ID).update_all(held_generation: nil)
      end
    end

    # The generation whose outbox rows the relay holds back, or nil.
    def self.held_generation
      where(id: SINGLETON_ID).pick(:held_generation)
    end

    # Holds back the outbox rows of generation until it is admitted. A first
    # cutover calls this as it writes its correction snapshots. An earlier
    # held generation belongs to an attempt that was aborted before its flip,
    # so its undelivered snapshots are removed: nothing else is ever written
    # at a held generation, and the projection would refuse them once this
    # generation flips. Call it inside the transaction that writes the rows.
    def self.hold_generation!(generation)
      previous = lock.where(id: SINGLETON_ID).pick(:held_generation)
      OutboxSnapshot.where(generation: previous, sent_at: nil).delete_all if previous && previous != generation
      where(id: SINGLETON_ID).update_all(held_generation: generation)
    end

    # The admitted generation and the settling generation, read together FOR
    # SHARE so stop_applying!, fence! and admit! wait for the calling
    # transaction to commit. Both nil when the row is missing.
    def self.locked_state
      row = connection.select_one(sanitize_sql_array(
        ["SELECT generation, settling_generation FROM admission WHERE id = ? FOR SHARE", SINGLETON_ID]
      ))
      LockedState.new(generation: row&.fetch("generation"), settling_generation: row&.fetch("settling_generation"))
    end

    # Opens the settle step of a handoff away from the outgoing generation:
    # while fenced, Timekeeping still applies a commit or abort it registered
    # at that generation. A late or repeated call never reopens a stopped step
    # or replaces a newer one (SettlingPhase.begin).
    def self.begin_settling!(generation:)
      change_settling_phase!(generation) { |state| SettlingPhase.begin(state, generation) }
    end

    # Ends the settle step for generation and raises the stop mark to it. A
    # late call for an older generation leaves a newer step open
    # (SettlingPhase.stop).
    def self.stop_applying!(generation:)
      change_settling_phase!(generation) { |state| SettlingPhase.stop(state, generation) }
    end

    # Whether a settle step is open. false when the row is missing.
    def self.settling?
      !where(id: SINGLETON_ID).pick(:settling_generation).nil?
    end

    # The settle step's transitions, as pure functions of the locked row. Each
    # returns the column changes to write, or nil when the call changes
    # nothing. A stop mark at or above a generation means that generation's
    # step was stopped and must stay stopped.
    module SettlingPhase
      def self.begin(state, generation)
        return unless state.generation.nil?
        return unless state.settling_stopped_generation.nil? || state.settling_stopped_generation < generation
        return unless state.settling_generation.nil? || state.settling_generation < generation

        { settling_generation: generation }
      end

      def self.stop(state, generation)
        return if state.settling_generation && state.settling_generation > generation

        { settling_generation: nil, settling_stopped_generation: [state.settling_stopped_generation, generation].compact.max }
      end
    end

    def self.change_settling_phase!(generation)
      check_generation!(generation)

      transaction do
        row = lock.where(id: SINGLETON_ID).pick(:generation, :settling_generation, :settling_stopped_generation)
        raise_missing if row.nil?

        changes = yield PhaseState.new(*row)
        where(id: SINGLETON_ID).update_all(changes) if changes
      end
    end
    private_class_method :change_settling_phase!

    # Only a positive Integer can ever match an Ownership-Generation header,
    # and a nil would read as "no generation", so anything else is refused
    # before the row is touched.
    def self.check_generation!(generation)
      raise ArgumentError, "generation must be a positive Integer" unless generation.is_a?(Integer) && generation.positive?
    end
    private_class_method :check_generation!

    def self.set_generation(generation)
      updated = where(id: SINGLETON_ID).update_all(generation:)
      raise_missing if updated.zero?
    end
    private_class_method :set_generation

    def self.raise_missing
      raise ActiveRecord::RecordNotFound.new("admission row is missing", name, primary_key, SINGLETON_ID)
    end
    private_class_method :raise_missing
  end
end

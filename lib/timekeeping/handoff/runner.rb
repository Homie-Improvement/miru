# frozen_string_literal: true

require "digest"

module Timekeeping
  module Handoff
    # Carries out the handoff of docs/architecture/timekeeping-soa.md section
    # 10.5: cutover, rollback and re-cutover, each with the seven steps of
    # Steps::TABLE under one rising generation. Steps.decide says what a call
    # should do; this class is the shell that does it, against the ownership
    # row, the two owners' stores and admission adapters, the legacy source,
    # the money snapshot and reconciliation.
    #
    # Progress lives on the ownership row, and a step is recorded there only
    # after its own work committed and its completion check passed, so any
    # interrupted run can be resumed or aborted by a fresh call. The step 2
    # money snapshot and the checkpoint's capture time and digests are kept in
    # a per-generation ReportDirectory, so a resumed run compares against the
    # same values as the run it continues.
    class Runner
      # A handoff that cannot start or go on. The row is left resumable or
      # abortable; nothing it refuses has changed the generation twice.
      class Refused < StandardError; end

      # How long closing admission waits for billing writes that hold the
      # ownership row FOR SHARE, as Timekeeping::Admission.fence! waits for
      # its own admitted writes.
      CLOSE_ADMISSION_LOCK_TIMEOUT = 60.seconds
      # One session advisory lock for every run, forward, resume or abort, so
      # a second run anywhere fails fast instead of racing the first.
      LOCK_SQL = "SELECT pg_try_advisory_lock(hashtextextended('timekeeping_handoff', 0))"
      UNLOCK_SQL = "SELECT pg_advisory_unlock(hashtextextended('timekeeping_handoff', 0))"
      CHANGED_BY = "timekeeping_handoff"
      # A resume reads the step 2 money snapshot and the checkpoint files a
      # previous run wrote, so they live under storage/, the directory that
      # persists between containers, not under log/.
      DEFAULT_REPORT_ROOT = Rails.root.join("storage", "timekeeping_handoff")
      PREPARED_MONOLITH_STORE = "prepared"
      PROJECTION_SQL = "SELECT * FROM timesheet_entries ORDER BY id"
      INTENTS_SQL = <<~SQL.squish
        SELECT #{Reconciliation::INTENT_COLUMNS.join(', ')} FROM invoice_operation_intents ORDER BY id
      SQL

      def self.run(direction:, resume: true, abort: false, owners: configured_owners, observer: NullObserver.new,
                   report_root: DEFAULT_REPORT_ROOT, clock: Time,
                   close_admission_lock_timeout: CLOSE_ADMISSION_LOCK_TIMEOUT)
        new(owners:, observer:, report_root:, clock:, close_admission_lock_timeout:)
          .run(direction: direction.to_sym, resume:, abort:)
      end

      # The owners as this application is configured. The monolith's
      # admission adapter and every settle and drain integration come from
      # config.x.timekeeping_handoff and are nil until one is supplied, so the
      # capability gate refuses a start that could not really fence writers.
      def self.configured_owners
        config = Rails.configuration.x.timekeeping_handoff
        timekeeping = TimekeepingStore.new
        {
          "monolith" => Owner.new(
            name: "monolith", store: MonolithStore.new(connection: ActiveRecord::Base.connection),
            admission: config.monolith_admission, settle: config.monolith_settle, drain: config.monolith_drain
          ),
          "timekeeping" => Owner.new(
            name: "timekeeping", store: timekeeping, admission: timekeeping,
            settle: config.timekeeping_settle, drain: config.timekeeping_drain
          )
        }
      end

      def initialize(owners:, observer:, report_root:, clock:, close_admission_lock_timeout:)
        @owners = owners.to_h.transform_keys(&:to_s)
        @observer = observer
        @report_root = Pathname(report_root)
        @clock = clock
        @close_admission_lock_timeout = close_admission_lock_timeout
      end

      def run(direction:, resume:, abort:)
        with_handoff_lock do
          ownership = TimekeepingOwnership.current
          decision = Steps.decide(ownership, direction:, abort:, resume:)
          raise Refused, decision.reason if decision.kind == :refuse

          if decision.kind == :readmit
            owner(decision.owner).admission.admit(generation: ownership.generation)
            next
          end

          prepare(Steps::DIRECTIONS.fetch(direction), ownership)
          case decision.kind
          when :start then carry_out(Steps::NAMES)
          when :resume then carry_out(Steps::NAMES.drop(Steps::NAMES.index(decision.step)))
          when :abort then abort_handoff(decision.owed)
          end
        end
        nil
      end

      private

        attr_reader :observer, :clock, :outgoing, :incoming, :source_legacy

        def with_handoff_lock
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            raise Refused, "Another Timekeeping handoff run holds the handoff lock" unless connection.select_value(LOCK_SQL)

            begin
              yield
            ensure
              connection.select_value(UNLOCK_SQL)
            end
          end
        end

        def owner(name)
          @owners.fetch(name.to_s)
        end

        # Resolves the direction's owners and whether its source is legacy
        # once, from the row, then refuses before any side effect when either
        # owner cannot fence its writers or the source cannot be settled.
        def prepare(route, ownership)
          @route = route
          @outgoing = owner(route[:from])
          @incoming = owner(route[:to])
          @source_legacy = ownership.source_legacy?
          @generation = ownership.handoff_step.nil? ? nil : ownership.generation

          refusal = Capabilities.new.refusal(source_legacy:, outgoing:, incoming:)
          raise Refused, refusal if refusal
        end

        # The one interpreter of Steps::TABLE: runs each step's action, then
        # its completion check, and records the step only when the check
        # passed. close_admission and flip write the row in their own
        # transaction, so recording them again is skipped.
        def carry_out(names)
          names.each do |name|
            step = Steps::TABLE.find { |row| row[:name] == name }
            observer.call(:before_step, step: name)
            send(step.fetch(:action))
            raise Refused, "The #{name} step did not finish; resume or abort the handoff" unless send(step.fetch(:completion_check))

            record(name) unless %w[close_admission flip].include?(name)
            observer.call(:after_step, step: name)
          end
        end

        # Finishes settle and freeze if they are owed, then reopens the
        # outgoing owner at the raised generation. The incoming owner stays
        # fenced, and the generation stays raised.
        def abort_handoff(owed)
          carry_out(owed)
          update_row { |row| row.handoff_step = nil }
          outgoing.admission.admit(generation: @generation)
        end

        # Step 1. Fences Timekeeping, whichever side it is on, because its
        # load refuses an unfenced Timekeeping and its admission starts open
        # at generation 1; then the monolith adapter when the monolith is
        # outgoing. Fencing again is harmless. The row update then waits for
        # billing writes holding the row FOR SHARE, for at most the lock
        # timeout, and raises the generation, records the step and clears P
        # in one transaction, so a timeout changes none of them.
        def close_admission
          owner("timekeeping").admission.fence_admission
          outgoing.admission.fence_admission if outgoing.equal?(owner("monolith"))

          read_generation = TimekeepingOwnership.current.generation
          updated = TimekeepingOwnership.transaction do
            timeout_ms = Integer(@close_admission_lock_timeout.in_milliseconds)
            TimekeepingOwnership.connection.execute("SET LOCAL lock_timeout = '#{timeout_ms}ms'")
            TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID, handoff_step: nil, generation: read_generation)
              .update_all(generation: read_generation + 1, handoff_step: "close_admission", final_outbox_position: nil,
                          changed_at: Time.current, changed_by: CHANGED_BY)
          end
          raise Refused, "The ownership row changed while admission was closing; run again" unless updated == 1

          @generation = read_generation + 1
        rescue ActiveRecord::LockWaitTimeout
          raise Refused, "Billing writes still hold the ownership row after #{@close_admission_lock_timeout.inspect}; " \
                         "resume or abort the handoff"
        end

        def admission_closed?
          ownership = TimekeepingOwnership.current
          ownership.generation == @generation && !ownership.handoff_step.nil?
        end

        # Step 2. The money snapshot is taken once every operation admitted
        # before step 1 has settled; billing writes stay refused from here to
        # the flip, so the snapshot after reconcile must equal it. A settle
        # repeated after its file was stored keeps that baseline.
        def settle
          settle_integration.settle!(generation: @generation)
          return unless settle_integration.settled? && !report.money_before?

          report.write_money_before(take_money)
        end

        def settled?
          settle_integration.settled?
        end

        # Step 3. Stops applying commit and abort, then stores P before the
        # drain: the projection consumer accepts previous-generation snapshots
        # up to the stored P, and freeze is recorded only after the drain.
        # A repeated freeze keeps the P already stored.
        def freeze
          settle_integration.stop_applying!
          @final_outbox_position = TimekeepingOwnership.current.final_outbox_position || store_final_outbox_position
          drain_integration.drain!(through: @final_outbox_position)
        end

        def drained?
          drain_integration.drained?(through: @final_outbox_position)
        end

        def store_final_outbox_position
          position = source_legacy ? 0 : outgoing.store.highest_outbox_position
          update_row(expected_step: "settle") { |row| row.final_outbox_position = position }
          position
        end

        # Step 4. With no stored checkpoint file the step has not started and
        # takes its capture time now; otherwise it reuses the stored one and
        # refuses a source that no longer matches the stored digest.
        def checkpoint
          refuse_unfenced_monolith_load! if incoming.equal?(owner("monolith"))
          observer.call(:during_checkpoint, step: "checkpoint")
          incoming.store.load_checkpoint(source_copy.fetch(:load))
          if source_legacy
            incoming.store.write_correction_snapshots(
              snapshots: correction_snapshots, version: ReservationDerivation::CORRECTION_VERSION, generation: @generation
            )
          end
          observer.call(:after_corrections, step: "checkpoint")
        end

        def checkpoint_loaded?
          incoming.store.export_checkpoint&.digest == source_copy.fetch(:load).digest
        end

        # Step 5. The incoming sequence only rises.
        def advance_sequence
          @next_entry_id = incoming.store.advance_entry_id_sequence(above: report.read_checkpoint.fetch(:highest_entry_id))
        end

        def sequence_advanced?
          @next_entry_id > report.read_checkpoint.fetch(:highest_entry_id)
        end

        # Step 6. Every check of section 10.4, company by company. The report
        # is written and its signals sent whatever the verdict; any unlisted
        # difference stops the handoff before reconcile is recorded.
        def reconcile
          next_entry_id = incoming.store.advance_entry_id_sequence(above: report.read_checkpoint.fetch(:highest_entry_id))
          intents = read_intents
          loaded = incoming.store.export_checkpoint
          # A restart after the checkpoint step skips its completion check, so
          # what the incoming owner holds is compared with the planned copy
          # again here, before anything can flip ownership to it.
          unless loaded&.digest == source_copy.fetch(:load).digest
            raise Refused, "The incoming owner no longer holds the checkpoint this handoff loaded"
          end
          @reconciliation = Reconciliation.run(
            source: source_copy.fetch(:source), checkpoint: loaded, projection: read_projection,
            source_intents: intents, intents:, next_entry_id:,
            money_before: report.read_money_before, money_after: take_money,
            listed_corrections: listed_corrections(intents),
            expected_reservations: source_legacy ? source_copy.fetch(:source).rows.fetch("reservations").group_by { |row| row["company_id"] } : nil
          )
          report.write_reconciliation(@reconciliation.to_h)
          Reconciliation.report(@reconciliation)
          raise Refused, "Reconciliation found unexplained differences; see #{report.path}" if @reconciliation.abort?
        end

        def reconciled?
          !@reconciliation.abort?
        end

        # Step 7. Requires reconcile recorded at this run's generation, moves
        # the owner and clears the step in one transaction, and only then lets
        # the incoming owner admit writes. A flip from the legacy source also
        # retires it: legacy_retired_at is set and the monolith's own store
        # becomes the prepared tables, so a later rollback lands there.
        def flip
          update_row(expected_step: "reconcile") do |row|
            row.owner = @route.fetch(:to)
            row.handoff_step = nil
            if source_legacy
              row.legacy_retired_at = Time.current
              row.monolith_store = PREPARED_MONOLITH_STORE
            end
          end
          incoming.admission.admit(generation: @generation)
        end

        def flipped?
          ownership = TimekeepingOwnership.current
          ownership.handoff_step.nil? && owner(ownership.owner).equal?(incoming)
        end

        def record(step)
          update_row { |row| row.handoff_step = step }
        end

        # Updates the row FOR UPDATE, only at this run's generation, while a
        # handoff is in progress and, when expected_step is given, only at
        # that step.
        def update_row(expected_step: nil)
          TimekeepingOwnership.transaction do
            row = TimekeepingOwnership.lock.find(TimekeepingOwnership::SINGLETON_ID)
            in_progress = !row.handoff_step.nil? && (expected_step.nil? || row.handoff_step == expected_step)
            unless row.generation == @generation && in_progress
              raise Refused, "The ownership row moved to generation #{row.generation} at step #{row.handoff_step.inspect}; " \
                             "this run expected generation #{@generation}#{" at #{expected_step}" if expected_step}"
            end

            yield row
            row.changed_at = Time.current
            row.changed_by = CHANGED_BY
            row.save!
          end
        end

        # MonolithStore's load runs no fence check of its own, so the runner
        # checks the row before replacing the monolith's prepared tables.
        def refuse_unfenced_monolith_load!
          ownership = TimekeepingOwnership.current
          return if ownership.generation == @generation && ownership.handoff_step == "freeze"

          raise Refused, "Refusing to load the monolith's tables outside this handoff's checkpoint step"
        end

        def settle_integration
          source_legacy ? legacy_operations_check : outgoing.settle
        end

        def drain_integration
          source_legacy ? legacy_operations_check : outgoing.drain
        end

        def legacy_operations_check
          @legacy_operations_check ||= LegacyOperationsCheck.new
        end

        def report
          @report ||= ReportDirectory.new(root: @report_root, generation: @generation)
        end

        # The frozen source and the copy loaded from it, built once per run.
        # The first build in a generation stores the capture time and digests;
        # every later build, after an interrupt or a restart, reuses that
        # capture time and must reproduce both stored digests, so a version
        # changed in the incoming owner meanwhile cannot reshape the plan.
        def source_copy
          @source_copy ||= begin
            stored = report.read_checkpoint if report.checkpoint?
            captured_at = stored ? stored.fetch(:captured_at) : clock.now.utc.floor(6)
            copy = export_source(captured_at)
            if stored.nil?
              report.write_checkpoint(
                captured_at:, source_digest: digest_text(copy.fetch(:source)), loaded_digest: digest_text(copy.fetch(:load)),
                highest_entry_id: copy.fetch(:source).rows.fetch("entries").pluck("id").max || 0
              )
            elsif digest_text(copy.fetch(:source)) != stored.fetch(:source_digest)
              raise Refused, "The frozen source no longer matches the checkpoint taken at #{captured_at.iso8601(6)}"
            elsif digest_text(copy.fetch(:load)) != stored.fetch(:loaded_digest)
              raise Refused, "The incoming owner's entries changed since the checkpoint taken at #{captured_at.iso8601(6)}"
            end
            copy
          end
        end

        def export_source(captured_at)
          unless source_legacy
            exported = outgoing.store.export_checkpoint
            return { source: exported, load: ReservationLocks.build(exported), corrections: [] }
          end

          exported = LegacySource.new(connection: ActiveRecord::Base.connection, recorded_disposition:)
            .export(generation: @generation, captured_at:)
          load = LegacyLoadVersions.build(source: exported.fetch(:checkpoint), corrections: exported.fetch(:corrections),
                                          stored: incoming.store.export_checkpoint)
          { source: exported.fetch(:checkpoint), load:, corrections: exported.fetch(:corrections) }
        end

        # The differences the planned load copy makes on purpose, derived from
        # that copy rather than from what the incoming owner now holds, so a
        # wrong load can never list its own difference as expected.
        def listed_corrections(intents)
          source, load = source_copy.values_at(:source, :load)
          planned = if source_legacy
            LegacyLoadVersions.listed_corrections(source:, loaded: load, corrections: source_copy.fetch(:corrections))
          else
            ReservationLocks.listed_corrections(source:, loaded: load)
          end
          legacy_receipts = LegacyOperationsCheck.listed_receipts(
            intents, legacy_retired_at: TimekeepingOwnership.current.legacy_retired_at
          )
          planned.merge(legacy_receipts) { |_company_id, differences, receipts| differences + receipts }
        end

        # The first cutover's corrections as the outbox rows Timekeeping's
        # correction writer takes: the corrected entry without its version,
        # which travels as its own argument.
        def correction_snapshots
          source_copy.fetch(:corrections).map { |correction| correction.fetch("snapshot").except("version") }
        end

        def recorded_disposition
          YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH)
        end

        # One snapshot per company, keyed by company id, so no company's
        # money is ever compared with or summed into another's.
        def take_money
          Company.order(:id).pluck(:id).index_with { |company_id| FinancialSnapshot.take(company_id:) }
        end

        def read_projection
          RowReader.select_rows(ActiveRecord::Base.connection, PROJECTION_SQL)
        end

        # Intents are written through InvoiceOperationsRecord's own
        # connection, so they are read on it too.
        def read_intents
          RowReader.select_rows(InvoiceOperationsRecord.connection, INTENTS_SQL)
        end

        # A stable text form of a checkpoint's per-company counts and
        # checksums, for the report file and for comparing a rebuilt source.
        def digest_text(checkpoint)
          canonical = checkpoint.digest.sort.map do |table, companies|
            [table, companies.sort.map { |company_id, entry| [company_id, entry.fetch(:count), entry.fetch(:checksum)] }]
          end
          Digest::SHA256.hexdigest(JSON.generate(canonical))
        end
    end
  end
end

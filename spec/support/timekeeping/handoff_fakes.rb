# frozen_string_literal: true

# A drain integration for Timekeeping::Handoff::Runner specs that stands in
# for the outbox relay: drain! copies every entry the outgoing owner's store
# holds into the monolith's timesheet_entries projection, as delivering the
# outbox through P would. The runner's reconcile step compares that
# projection with the checkpoint, so a fake drain that wrote nothing would
# leave every change made under the outgoing owner as an unexplained
# difference.
class TimekeepingHandoffFakeRelay
  ENUM_COLUMNS = { "bill_status" => :bill_statuses, "review_status" => :review_statuses }.freeze

  attr_reader :drained_through

  # store: the outgoing owner's checkpoint store. log, when given, receives
  # [:drain, through] for each drain, so specs can check the call order.
  def initialize(store:, log: nil)
    @store = store
    @log = log
  end

  def drain!(through:)
    @log&.push([:drain, through])
    checkpoint = @store.export_checkpoint
    checkpoint&.rows&.fetch("entries")&.each { |row| write_projection_row(row) }
    @drained_through = through
  end

  def drained?(through:)
    @drained_through == through
  end

  private

    def write_projection_row(row)
      connection = TimesheetEntry.connection
      columns = TimesheetEntry.columns_hash
      assignments = (Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries") - ["id"]).map do |column|
        value = projection_value(column, row.fetch(column))
        "#{connection.quote_column_name(column)} = " \
          "#{Timekeeping::Handoff::LosslessSql.literal(connection, value, columns.fetch(column))}"
      end
      connection.execute("UPDATE timesheet_entries SET #{assignments.join(', ')} WHERE id = #{Integer(row.fetch('id'))}")
    end

    # timesheet_entries stores bill_status and review_status as integer enums.
    def projection_value(column, value)
      enum = ENUM_COLUMNS[column]
      enum ? TimesheetEntry.public_send(enum).fetch(value, value) : value
    end
end

# The owner-side fakes every Timekeeping::Handoff::Runner spec shares. One copy
# of each keeps the specs from drifting apart: a looser private copy of the
# store would let a runner bug pass where the real store refuses it.
module TimekeepingHandoffFakes
  # An admission adapter that only records what it was told. calls keeps
  # [:fence] and [:admit, generation]. log, when given, also receives each
  # call, prefixed with tag when one is given, so a spec can read the order of
  # admission calls among settle, drain and observer records in one array.
  class RecordingAdmission
    attr_reader :calls

    def initialize(log: nil, tag: nil, enforces_fence: true)
      @calls = []
      @log = log
      @tag = tag
      @enforces_fence = enforces_fence
    end

    def enforces_fence? = @enforces_fence

    def fence_admission
      record([:fence])
      nil
    end

    def admit(generation:)
      record([:admit, generation])
      nil
    end

    private

      def record(call)
        @calls << call
        @log&.push(@tag ? [@tag, *call] : call)
      end
  end

  # Timekeeping's side of the handoff, held in memory at the store's client
  # boundary (Timekeeping::Handoff::TimekeepingStore). Like that store it is
  # also its own admission adapter. It keeps the version guards the real load
  # applies: every entry version is a positive Integer, and a load never
  # replaces an entry with an older version of it. Corrections replace any
  # earlier correction of the same entry and raise the stored version, as the
  # service's correction writer does.
  class InMemoryTimekeepingStore < RecordingAdmission
    attr_reader :rows, :corrections

    def initialize(log: nil, tag: nil)
      super
      @rows = Timekeeping::Handoff::Checkpoint::TABLES.keys.index_with { [] }
      @corrections = []
      @next_id = 1
    end

    def export_checkpoint = Timekeeping::Handoff::Checkpoint.build(tables: @rows)

    def highest_outbox_position = 0

    def load_checkpoint(checkpoint)
      not_positive = checkpoint.rows.fetch("entries").reject { |row| row["version"].is_a?(Integer) && row["version"].positive? }
      raise Timekeeping::Handoff::Store::Error, "entries #{not_positive.pluck('id')} have a version below 1" if not_positive.any?

      stored = @rows.fetch("entries").to_h { |row| [row["id"], row["version"]] }
      older = checkpoint.rows.fetch("entries").any? { |row| stored.fetch(row["id"], -1) > row["version"] }
      raise Timekeeping::Handoff::Store::Error, "the store holds newer entry versions than the checkpoint" if older

      @rows = checkpoint.rows.transform_values { |rows| rows.map(&:dup) }
      checkpoint
    end

    def advance_entry_id_sequence(above:)
      @next_id = [@next_id, Integer(above) + 1].max
    end

    def write_correction_snapshots(snapshots:, version:, generation:)
      snapshots.each do |snapshot|
        entry_id = self.class.entry_id_of(snapshot)
        @corrections.reject! { |stored| self.class.entry_id_of(stored) == entry_id }
        @corrections << snapshot.merge("version" => version, "generation" => generation)
        entry = @rows.fetch("entries").find { |row| row["id"] == entry_id }
        entry["version"] = version if entry && entry["version"] < version
      end
      snapshots.size
    end

    # An entry edit admitted while Timekeeping owns the entries.
    def edit_entry!(id)
      entry = @rows.fetch("entries").find { |row| row["id"] == id }
      entry["version"] += 1
      entry["note"] = "edited in Timekeeping"
    end

    def self.entry_id_of(snapshot)
      snapshot["entry_id"] || snapshot.dig("snapshot", "id") || snapshot["id"]
    end
  end

  # A settle integration with nothing left to settle.
  class NoOpSettle
    def settle!(generation:) = nil
    def settled? = true
    def stop_applying! = nil
  end

  # Builds the monolith and Timekeeping owners a runner spec hands to the
  # runner. By default the Timekeeping store is also Timekeeping's admission
  # adapter, and each owner's drain relays that owner's entries into the
  # projection, as the real outbox relay would, so reconcile sees the
  # projection the drain left. relay: false leaves both drains nil; log is
  # passed to the relays so drains appear in a spec's shared call log.
  def self.owners(timekeeping:, timekeeping_admission: timekeeping, monolith_admission: RecordingAdmission.new,
                  monolith_store: Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection),
                  settle: NoOpSettle.new, relay: true, log: nil)
    drain_for = ->(store) { relay ? TimekeepingHandoffFakeRelay.new(store:, log:) : nil }
    {
      monolith: Timekeeping::Handoff::Owner.new(
        name: :monolith, store: monolith_store, admission: monolith_admission, settle:, drain: drain_for.call(monolith_store)
      ),
      timekeeping: Timekeeping::Handoff::Owner.new(
        name: :timekeeping, store: timekeeping, admission: timekeeping_admission, settle:,
        drain: drain_for.call(timekeeping)
      )
    }
  end
end

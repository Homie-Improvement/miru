# frozen_string_literal: true

# A drain integration for Timekeeping::Handoff::Runner specs that stands in
# for the outbox relay: drain! copies every entry the outgoing owner's store
# holds into the monolith's timesheet_entries projection, as delivering the
# outbox through P would. The outbox publishes locked as the entry's
# reservations say, not the stored entries.locked column, which neither
# Timekeeping nor the monolith's prepared store keeps current, so each entry
# is written with locked from ReservationLocks.build, the same rule the
# runner applies to a non-legacy load. The runner's reconcile step compares that
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
    published = checkpoint && Timekeeping::Handoff::ReservationLocks.build(checkpoint)
    published&.rows&.fetch("entries")&.each { |row| write_projection_row(row) }
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

# A drain integration for Timekeeping as the outgoing owner that delivers only
# the rows in TimekeepingHandoffFakes::InMemoryTimekeepingStore#outbox, through
# the real Timekeeping::ProjectionConsumer, by way of the gem's own
# TimekeepingRelay::Relay. It never copies stored entries into the projection,
# so an entry whose snapshot was left out of the outbox stays behind there and
# the runner's reconcile reports it, as it would on a live rollback.
#
# Like the real relay, it holds back rows of a generation Timekeeping has not
# admitted yet (the store records each admit call), and drain! delivers only
# rows at or below through.
class TimekeepingHandoffOutboxRelay
  # Raised when a row this drain owes stays unsent, so a batch the consumer
  # refused (409, 422 or any other answer) fails the spec with its status and
  # body instead of reading as a projection left behind.
  class Undelivered < StandardError; end

  BATCH_LIMIT = 100

  # The outbox rows this drain may deliver, as TimekeepingRelay::OutboxSource
  # rows with each entry in the contract's wire shape.
  class Source
    include TimekeepingRelay::OutboxSource

    def initialize(store:, through:, sent_positions:)
      @store = store
      @through = through
      @sent_positions = sent_positions
    end

    def unsent_after(position, limit)
      owed.select { |row| row.fetch("outbox_position") > position }.first(limit)
          .map { |row| row.merge("entry" => TimekeepingHandoffOutboxRelay.wire_entry(row.fetch("entry"))) }
    end

    def mark_sent(positions)
      @sent_positions.merge(positions)
      nil
    end

    # Admitted, at or below through, and not yet sent, in position order.
    def owed
      admitted = @store.calls.filter_map { |call| call.last if call.first == :admit }
      @store.outbox
            .select { |row| admitted.include?(row.fetch("generation")) && row.fetch("outbox_position") <= @through }
            .reject { |row| @sent_positions.include?(row.fetch("outbox_position")) }
            .sort_by { |row| row.fetch("outbox_position") }
    end
  end

  # Calls the projection consumer in process, as the monolith's snapshot
  # endpoint does, and keeps the last answer for the Undelivered message.
  class ConsumerEndpoint
    attr_reader :last_response

    def deliver(batch, idempotency_key:)
      result = Timekeeping::ProjectionConsumer.call(batch:, idempotency_key:)
      @last_response = TimekeepingRelay::Response.new(status: result.status, body: result.body)
    end
  end

  # A stored entry as the contract's entry fields, with times and dates as
  # ISO 8601 text, as the service's outbox serializes them. Every other value
  # is sent as stored, so a missing field or a lock that is not a boolean
  # reaches the consumer and is refused there, as it would be live.
  def self.wire_entry(entry)
    entry.slice(*Timekeeping::SnapshotBatch::ENTRY_FIELDS).transform_values { |value| wire_value(value) }
  end

  def self.wire_value(value)
    case value
    when ActiveSupport::TimeWithZone, Time, DateTime then value.to_time.utc.iso8601(6)
    when Date then value.iso8601
    else value
    end
  end

  # store: Timekeeping's InMemoryTimekeepingStore. log, when given, receives
  # [:drain, through] for each drain, so specs can check the call order.
  # paused is handed to the gem's relay, which checks it before every POST, so
  # a spec can pause delivery the way the live relay is paused.
  def initialize(store:, log: nil, paused: TimekeepingRelay::Relay::NEVER_PAUSED)
    @store = store
    @log = log
    @paused = paused
    @sent_positions = Set.new
  end

  # A paused relay holds rows back without losing them, so only a drain that
  # ran unpaused and still left rows owed is a failed delivery.
  def drain!(through:)
    @log&.push([:drain, through])
    source = source_through(through)
    endpoint = ConsumerEndpoint.new
    TimekeepingRelay::Relay.new(source:, endpoint:, paused: @paused).deliver(limit: BATCH_LIMIT)
    return if source.owed.empty? || @paused.call

    answer = endpoint.last_response
    raise Undelivered, "outbox rows at or below position #{through} were not delivered: " \
                       "status #{answer&.status.inspect}, body #{answer&.body.inspect}"
  end

  def drained?(through:)
    source_through(through).owed.empty?
  end

  private

    def source_through(through)
      Source.new(store: @store, through:, sent_positions: @sent_positions)
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
  #
  # It also keeps Timekeeping's outbox: every correction and every entry edit
  # adds a row, so a relay that delivers only outbox rows sees exactly what the
  # real service would publish, and an entry with no row stays behind.
  class InMemoryTimekeepingStore < RecordingAdmission
    # corrections holds what the service keeps, one per entry; correction_writes
    # holds every snapshot as sent, so a spec can catch a duplicated write that
    # the replacement would otherwise absorb. outbox holds
    # { "generation", "outbox_position", "entry" } rows in position order, each
    # entry with its version.
    attr_reader :rows, :corrections, :correction_writes, :outbox

    def initialize(log: nil, tag: nil)
      super
      @rows = Timekeeping::Handoff::Checkpoint::TABLES.keys.index_with { [] }
      @corrections = []
      @correction_writes = []
      @outbox = []
      @next_outbox_position = 1
      @next_id = 1
    end

    def export_checkpoint = Timekeeping::Handoff::Checkpoint.build(tables: @rows)

    # 0 for an empty outbox, the position no snapshot is ever written at.
    def highest_outbox_position = @outbox.map { |row| row.fetch("outbox_position") }.max || 0

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
        @correction_writes << snapshot
        entry_id = self.class.entry_id_of(snapshot)
        @corrections.reject! { |stored| self.class.entry_id_of(stored) == entry_id }
        @corrections << snapshot.merge("version" => version, "generation" => generation)
        # Like the service's writer, a rewrite replaces this entry's row at this
        # generation only; rows of other entries and generations stay.
        @outbox.reject! { |row| row["generation"] == generation && self.class.entry_id_of(row["entry"]) == entry_id }
        append_outbox_row(snapshot.merge("version" => version), generation:)
        entry = @rows.fetch("entries").find { |row| row["id"] == entry_id }
        entry["version"] = version if entry && entry["version"] < version
      end
      snapshots.size
    end

    # An entry edit admitted while Timekeeping owns the entries. Its snapshot
    # goes to the outbox at the generation Timekeeping last admitted, as the
    # service's writer publishes every edit. Like Timekeeping::OutboxFields.row,
    # the snapshot's locked is whether a reservation holds the entry, never the
    # stored entries.locked column, which the service does not keep current.
    def edit_entry!(id)
      generation = last_admitted_generation
      raise ArgumentError, "edit_entry! needs an admitted generation; this store admitted none" if generation.nil?

      entry = @rows.fetch("entries").find { |row| row["id"] == id }
      entry["version"] += 1
      entry["note"] = "edited in Timekeeping"
      append_outbox_row(entry.merge("locked" => reserved?(entry)), generation:)
    end

    def self.entry_id_of(snapshot)
      snapshot["entry_id"] || snapshot.dig("snapshot", "id") || snapshot["id"]
    end

    private

      def append_outbox_row(entry, generation:)
        @outbox << { "generation" => generation, "outbox_position" => @next_outbox_position, "entry" => entry }
        @next_outbox_position += 1
      end

      def reserved?(entry)
        @rows.fetch("reservations").any? do |reservation|
          reservation["company_id"] == entry["company_id"] && reservation["entry_id"] == entry["id"]
        end
      end

      def last_admitted_generation
        calls.reverse_each.find { |call| call.first == :admit }&.last
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
  # adapter, the monolith's drain copies its entries into the projection, and
  # Timekeeping's drain is a TimekeepingHandoffOutboxRelay, which delivers only
  # the snapshots the store wrote to its outbox, so a rollback spec fails when
  # a snapshot is missing. That relay reads admitted generations from the
  # store, so it needs the store to be Timekeeping's admission. relay: false
  # leaves both drains nil. log is passed to the relays so drains appear in a
  # spec's shared call log.
  def self.owners(timekeeping:, timekeeping_admission: timekeeping, monolith_admission: RecordingAdmission.new,
                  monolith_store: Timekeeping::Handoff::MonolithStore.new(connection: ActiveRecord::Base.connection),
                  settle: NoOpSettle.new, relay: true, log: nil)
    drains = RELAY_DRAINS.fetch(relay)
    if drains.fetch(:timekeeping) == TimekeepingHandoffOutboxRelay && !timekeeping_admission.equal?(timekeeping)
      raise ArgumentError, "the outbox relay needs the store as Timekeeping's admission, " \
                           "or it never sees which generations were admitted"
    end

    drain_for = ->(name, store) { drains.fetch(name)&.new(store:, log:) }
    {
      monolith: Timekeeping::Handoff::Owner.new(
        name: :monolith, store: monolith_store, admission: monolith_admission, settle:,
        drain: drain_for.call(:monolith, monolith_store)
      ),
      timekeeping: Timekeeping::Handoff::Owner.new(
        name: :timekeeping, store: timekeeping, admission: timekeeping_admission, settle:,
        drain: drain_for.call(:timekeeping, timekeeping)
      )
    }
  end

  # The drain class each owner gets for each value of owners' relay: keyword.
  RELAY_DRAINS = {
    true => { monolith: TimekeepingHandoffFakeRelay, timekeeping: TimekeepingHandoffOutboxRelay },
    false => { monolith: nil, timekeeping: nil }
  }.freeze
end

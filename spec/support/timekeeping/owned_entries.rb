# frozen_string_literal: true

require_relative "local_owner_arrange"
require_relative "owner_state"
require_relative "regression_adapter"

# Arranges time entries in the store that owns them in an ownership state, so
# a characterization spec tests the owner instead of rows saved straight into
# timesheet_entries, which only the legacy state reads:
#
# - legacy: timesheet_entries;
# - timekeeping: the live Timekeeping app, through a checkpoint load, plus the
#   projection rows in timesheet_entries;
# - rollback: the prepared entries table Timekeeping::EntryLookup.local_entry
#   reads, plus the projection rows.
#
# The functions of this module are pure: they turn the rows a spec passes into
# entry attributes and checkpoint rows. TimekeepingOwnedEntries::Arrange,
# included into every example, does the writes and reads.
module TimekeepingOwnedEntries
  ROW_KEYS = %i[company user project id work_date duration note bill_status locked source_metadata].freeze
  REQUIRED_ROW_KEYS = %i[company user project].freeze
  OPTIONAL_COLUMNS = %w[work_date duration note bill_status locked source_metadata].freeze

  # LocalOwnerArrange's defaults, plus the values the entries table and the
  # checkpoint expect when a row names no note or lock.
  ENTRY_DEFAULTS = TimekeepingContract::LocalOwnerArrange::ENTRY_DEFAULTS.merge("note" => "", "locked" => false).freeze

  # The checkpoint columns a spec row does not set, as monolith_store_spec's
  # entry_row fills them, so Timekeeping's checkpoint value checks accept them.
  CHECKPOINT_ENTRY_DEFAULTS = {
    "version" => 1, "review_status" => "not_required", "source" => "manual", "source_metadata" => {},
    "proof_metadata" => {}
  }.freeze

  module_function

  # rows as entry attribute hashes with string keys, in input order. "id" is
  # nil for a row that names none. Raises ArgumentError for a row that is not
  # a Hash, lacks a required key or names an unknown one.
  def normalize(rows)
    rows.map do |row|
      raise ArgumentError, "each row must be a Hash, got #{row.inspect}" unless row.is_a?(Hash)

      row = row.transform_keys(&:to_sym)
      unknown = row.keys - ROW_KEYS
      missing = REQUIRED_ROW_KEYS - row.keys
      raise ArgumentError, "unknown row keys: #{unknown.join(', ')}" if unknown.any?
      raise ArgumentError, "missing row keys: #{missing.join(', ')}" if missing.any?

      entry_attributes(row)
    end
  end

  def entry_attributes(row)
    optional = row.slice(*OPTIONAL_COLUMNS.map(&:to_sym)).compact.transform_keys(&:to_s)
    attributes = ENTRY_DEFAULTS.merge(optional).merge(
      "id" => row[:id] && integer_id(row[:id]),
      "company_id" => record_id(row.fetch(:company)),
      "user_id" => record_id(row.fetch(:user)),
      "project_id" => record_id(row.fetch(:project))
    )
    attributes.merge("work_date" => date(attributes.fetch("work_date")),
                     "duration" => Float(attributes.fetch("duration")))
  end

  # A record is read by its id; anything else must be an integer id.
  def record_id(value)
    value.respond_to?(:id) ? value.id : integer_id(value)
  end

  # Base 10 for strings, so "010" is 10 and not an octal 8.
  def integer_id(value)
    value.is_a?(String) ? Integer(value, 10) : Integer(value)
  end

  def date(value)
    value.is_a?(String) ? Date.iso8601(value) : value
  end

  # Ids given more than once in ids, or already in arranged_ids.
  def repeated_ids(ids, arranged_ids)
    given = ids.compact
    (given.tally.select { |_id, count| count > 1 }.keys + (given & arranged_ids)).uniq
  end

  def checkpoint_entry_row(entry, stamp)
    Timekeeping::Handoff::Checkpoint::TABLES.fetch("entries").index_with { nil }
      .merge(CHECKPOINT_ENTRY_DEFAULTS, "created_at" => stamp, "updated_at" => stamp)
      .merge(entry)
  end

  # A checkpoint holding entry_rows, with every other table empty.
  def checkpoint_of(entry_rows)
    tables = Timekeeping::Handoff::Checkpoint::TABLES.keys.index_with { [] }.merge("entries" => entry_rows)
    Timekeeping::Handoff::Checkpoint.build(tables:)
  end

  module Arrange
    # Methods of this module, keyed by owner state: the one that writes the
    # owner's rows, and whether the projection in timesheet_entries is written
    # after it. In legacy the owner is timesheet_entries itself.
    OWNED_ENTRY_WRITERS = {
      "legacy" => { owner: :create_timesheet_entries, projection: false },
      "timekeeping" => { owner: :load_timekeeping_entries, projection: true },
      "rollback" => { owner: :create_prepared_entries, projection: true }
    }.freeze

    OWNED_ENTRY_READERS = {
      "legacy" => :read_legacy_owned_entry,
      "timekeeping" => :read_timekeeping_owned_entry,
      "rollback" => :read_prepared_owned_entry
    }.freeze

    OWNED_ENTRY_LISTERS = {
      "legacy" => :list_legacy_owned_entries,
      "timekeeping" => :list_timekeeping_owned_entries,
      "rollback" => :list_prepared_owned_entries
    }.freeze

    # reservations.invoice_id has no foreign key. A locked fixture only needs a
    # reservation row to exist for its entry, so no invoice is created.
    LOCKED_FIXTURE_INVOICE_ID = 1

    # Writes rows to the store that owns entries in state and returns their
    # ids in input order. Every check runs before the first write: an unknown
    # state, a malformed row, an id repeated in rows or repeating one arranged
    # earlier in this example (ArgumentError), and a missing live app in the
    # timekeeping state.
    def arrange_owned_entries(rows, state: TimekeepingOwnerState.current, timekeeping_store: nil)
      TimekeepingOwnerState.fetch(state)
      writer = OWNED_ENTRY_WRITERS.fetch(state)
      entries = TimekeepingOwnedEntries.normalize(rows)
      repeated = TimekeepingOwnedEntries.repeated_ids(entries.pluck("id"), arranged_owned_entry_ids)
      raise ArgumentError, "entry ids already arranged in this example: #{repeated.join(', ')}" if repeated.any?

      store = state == "timekeeping" ? (timekeeping_store || live_owned_entry_store) : nil
      entries = with_drawn_ids(entries)

      send(writer.fetch(:owner), entries, state:, store:)
      # Recorded once the owner holds the rows: a call that failed before this
      # can be retried, and one whose projection fails below cannot.
      @arranged_owned_entry_ids = arranged_owned_entry_ids + entries.pluck("id")
      create_timesheet_entries(entries) if writer.fetch(:projection)
      entries.pluck("id")
    end

    # One entry's fields, as a Hash with string keys, from the store that owns
    # entries in state; never from the projection in the timekeeping and
    # rollback states. Raises when the owner holds no such entry.
    def owned_entry(id, state: TimekeepingOwnerState.current)
      TimekeepingOwnerState.fetch(state)
      send(OWNED_ENTRY_READERS.fetch(state), TimekeepingOwnedEntries.integer_id(id))
    end

    # Every entry the store that owns entries in state holds, in id order, as
    # Hashes with the same string keys owned_entry returns. Lets a spec show
    # that the owner holds no entry matching some fields, which a read by id
    # cannot, without falling back to the projection.
    def owned_entries(state: TimekeepingOwnerState.current)
      TimekeepingOwnerState.fetch(state)
      send(OWNED_ENTRY_LISTERS.fetch(state))
    end

    private

      def arranged_owned_entry_ids
        @arranged_owned_entry_ids || []
      end

      # The rows loaded into Timekeeping so far in this example. A checkpoint
      # load replaces whole tables, so every load carries all of them.
      def timekeeping_owned_entry_rows
        @timekeeping_owned_entry_rows || []
      end

      # Gives each entry without an id one drawn from the timesheet_entries
      # sequence. An explicit id does not move that sequence, so a drawn value
      # equal to an id given in this batch or arranged earlier in the example
      # is skipped; otherwise the write would fail after the owner row exists.
      def with_drawn_ids(entries)
        taken = Set.new(arranged_owned_entry_ids + entries.filter_map { |entry| entry["id"] })
        entries.map do |entry|
          next entry if entry["id"]

          id = next_timesheet_entry_id
          id = next_timesheet_entry_id while taken.include?(id)
          taken << id
          entry.merge("id" => id)
        end
      end

      # Drawn from the timesheet_entries sequence, so the owner row and its
      # projection share an id that no later local row can take.
      def next_timesheet_entry_id
        ApplicationRecord.connection.select_value("SELECT nextval(pg_get_serial_sequence('timesheet_entries', 'id'))").to_i
      end

      def live_owned_entry_store
        live = TimekeepingRegressionAdapter.current
        unless live
          raise "No live Timekeeping adapter is running: set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1, " \
                "select the timekeeping owner state with a _test TIMEKEEPING_DATABASE_URL, or pass timekeeping_store:"
        end

        Timekeeping::Handoff::TimekeepingStore.new(base_url: live.base_url, token: live.service_token)
      end

      # TimesheetEntry refuses to create a billed row, so a billed entry is
      # created non-billable and then marked billed without callbacks.
      def create_timesheet_entries(entries, **)
        entries.each do |entry|
          attributes = entry.slice("id", "user_id", "project_id", "work_date", "duration", "note", "bill_status",
                                   "locked", "source_metadata")
          billed = attributes.fetch("bill_status") == "billed"
          attributes = attributes.merge("bill_status" => "non_billable") if billed
          record = TimesheetEntry.create!(attributes)
          record.update_column(:bill_status, "billed") if billed
        end
      end

      def create_prepared_entries(entries, **)
        entries.each do |entry|
          Timekeeping::LocalEntry.create!(entry)
          insert_fixture_reservation(entry) if entry.fetch("locked")
        end
        advance_prepared_entry_ids(above: entries.pluck("id").max)
      end

      # The rows above carry ids from the timesheet_entries sequence, which
      # leaves the entries sequence behind. The local owner draws new entry ids
      # from that sequence, so it is moved past the arranged ids, never back.
      def advance_prepared_entry_ids(above:)
        connection = ApplicationRecord.connection
        sequence = connection.select_value("SELECT pg_get_serial_sequence('entries', 'id')")
        last_value = connection.select_value("SELECT last_value FROM #{sequence}").to_i
        connection.select_value(
          ApplicationRecord.sanitize_sql_array(["SELECT setval(?, ?, true)", sequence, [last_value, above].max])
        )
      end

      # EntryLookup.local_entry reads locked from the reservations table, never
      # the stored column, so a locked entry needs a reservation row.
      def insert_fixture_reservation(entry)
        values = [entry.fetch("company_id"), entry.fetch("id"), LOCKED_FIXTURE_INVOICE_ID, SecureRandom.uuid]
        ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([<<~SQL.squish, *values]))
          INSERT INTO reservations (company_id, entry_id, invoice_id, operation_id, state, disposition, created_at)
          VALUES (?, ?, ?, ?, 'committed', 'active', NOW())
        SQL
      end

      # Loads the union of this example's rows and the new ones. Timekeeping
      # refuses a load unless admission is fenced, and its load leaves the
      # entries id sequence alone, so the sequence is moved above the highest
      # loaded id before admission is restored at the state's generation.
      def load_timekeeping_entries(entries, state:, store:)
        stamp = Time.current.utc.floor(6)
        union = timekeeping_owned_entry_rows +
                entries.map { |entry| TimekeepingOwnedEntries.checkpoint_entry_row(entry, stamp) }
        checkpoint = TimekeepingOwnedEntries.checkpoint_of(union)
        generation = TimekeepingOwnerState.fetch(state).fetch(:admission_generation)

        load_while_fenced(store, checkpoint, highest_id: union.pluck("id").max, generation:)
        @timekeeping_owned_entry_rows = union
      end

      def load_while_fenced(store, checkpoint, highest_id:, generation:)
        load_error = nil
        begin
          store.fence_admission
          store.load_checkpoint(checkpoint)
          store.advance_entry_id_sequence(above: highest_id)
        rescue StandardError => error
          load_error = error
          raise
        ensure
          restore_admission(store, generation, load_error)
        end
      end

      # An admit failure propagates only when nothing else failed first, so it
      # never hides the error that stopped the load.
      def restore_admission(store, generation, earlier_error)
        store.admit(generation:)
      rescue StandardError
        raise unless earlier_error
      end

      def read_legacy_owned_entry(id)
        TimesheetEntry.unscoped.find(id).attributes
      end

      def list_legacy_owned_entries
        TimesheetEntry.unscoped.order(:id).map(&:attributes)
      end

      def read_prepared_owned_entry(id)
        prepared_entry_fields(Timekeeping::LocalEntry.with_reserved.find(id))
      end

      def list_prepared_owned_entries
        Timekeeping::LocalEntry.with_reserved.order(:id).map { |row| prepared_entry_fields(row) }
      end

      def prepared_entry_fields(row)
        row.attributes.except("reserved").merge("locked" => row.reserved)
      end

      def read_timekeeping_owned_entry(id)
        tables = live_owned_entry_store.export_checkpoint.rows
        row = tables.fetch("entries").find { |entry| entry.fetch("id") == id } ||
              raise(ActiveRecord::RecordNotFound, "Timekeeping holds no entry #{id}")
        timekeeping_entry_fields(row, tables.fetch("reservations"))
      end

      def list_timekeeping_owned_entries
        tables = live_owned_entry_store.export_checkpoint.rows
        reservations = tables.fetch("reservations")
        tables.fetch("entries").sort_by { |row| row.fetch("id") }
              .map { |row| timekeeping_entry_fields(row, reservations) }
      end

      # Timekeeping, like the prepared store, treats an entry as locked exactly
      # when a reservation of the same company holds it, so locked is read from
      # the exported reservations rather than the stored column.
      def timekeeping_entry_fields(row, reservations)
        reserved = reservations.any? do |reservation|
          reservation.fetch("entry_id") == row.fetch("id") && reservation.fetch("company_id") == row.fetch("company_id")
        end
        row.merge("locked" => reserved)
      end
  end
end

RSpec.configure do |config|
  config.include TimekeepingOwnedEntries::Arrange
end

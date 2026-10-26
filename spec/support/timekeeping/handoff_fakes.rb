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

# frozen_string_literal: true

require "rails_event_viewer/adapters/active_record"

class RailsEventViewer::TransactionalAdapter < RailsEventViewer::Adapters::ActiveRecord
  # Isolate event insert failures so they cannot poison the business transaction.
  # Events are written synchronously (config.async = false), so the write
  # happens when the event does. occurred_at is taken from the application
  # clock, as created_at is, instead of the event's raw system-clock stamp, so
  # readers that compare it with Time.current (the timekeeping:alerts lookback)
  # use one clock.
  def write_events(events)
    occurred_at = Time.current
    RailsEventViewer::Entry.transaction(requires_new: true) do
      super(events.map { |event| event.merge(occurred_at:) })
    end
  end

  # Remove the viewer's default sort before PostgreSQL aggregate queries.
  def event_time_span(relation)
    row = build_scope(relation).reorder(nil).pick(Arel.sql("MIN(occurred_at)"), Arel.sql("MAX(occurred_at)"))
    row ? row.map { |value| parse_timestamp(value) } : [nil, nil]
  end
end

RailsEventViewer.configure do |config|
  config.async = false
  config.storage_adapter = RailsEventViewer::TransactionalAdapter
  config.captured_events = [/\A(?:Clients|Companies|Expenses|Imports|Invitations|Invoices|Payments|Projects|Timekeeping|TimesheetEntries|Users)::/]
  config.group_keys = [:request_id, :data_import_id]
  config.authentication = ->(controller) { controller.current_user&.event_viewer? }
end

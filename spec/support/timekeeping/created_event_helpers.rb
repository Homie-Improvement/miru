# frozen_string_literal: true

# Captures the TimesheetEntries::Created events an entry write raises, so a
# spec can count them and read their payload without leaving a subscriber
# behind.
module TimekeepingCreatedEventHelpers
  CREATED_EVENT_NAME = "TimesheetEntries::Created"

  # Returns every TimesheetEntries::Created event raised while the block runs,
  # in the order raised. The subscriber is removed even when the block raises.
  def timesheet_entries_created_events
    events = []
    subscriber = Object.new
    subscriber.define_singleton_method(:emit) { |event| events << event if event[:name] == CREATED_EVENT_NAME }
    Rails.event.subscribe(subscriber)
    begin
      yield
    ensure
      Rails.event.unsubscribe(subscriber)
    end
    events
  end
end

RSpec.configure do |config|
  config.include TimekeepingCreatedEventHelpers
end

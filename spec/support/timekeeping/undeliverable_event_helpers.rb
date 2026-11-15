# frozen_string_literal: true

# Captures the undeliverable-operation events an outbox delivery sends, so a
# spec can check what the event exposes without leaving a subscriber behind.
module TimekeepingUndeliverableEventHelpers
  # Returns the payload of every undeliverable-operation event sent while the
  # block runs, with symbol keys.
  def undeliverable_operation_event_payloads
    events = []
    subscriber = Object.new
    subscriber.define_singleton_method(:emit) { |event| events << event }
    Rails.event.subscribe(subscriber)
    begin
      yield
    ensure
      Rails.event.unsubscribe(subscriber)
    end
    events.filter_map do |event|
      event[:payload].to_h.symbolize_keys if event[:name] == Invoices::UndeliverableOperation::NAME
    end
  end
end

RSpec.configure do |config|
  config.include TimekeepingUndeliverableEventHelpers
end

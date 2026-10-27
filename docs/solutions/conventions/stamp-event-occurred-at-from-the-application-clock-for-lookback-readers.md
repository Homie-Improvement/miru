---
module: timekeeping
date: 2026-10-27
problem_type: convention
component: observability
severity: medium
evidence_grounding: anchored
grounding_evidence: "PR #196 changes RailsEventViewer::TransactionalAdapter#write_events in config/initializers/rails_event_viewer.rb to merge occurred_at: Time.current into each event, with a comment naming the timekeeping:alerts lookback as the reader. Lookback boundary specs in spec/tasks/timekeeping_alerts_5_2_spec.rb report events under travel_to and expect inclusion by occurred_at."
audience: both
related_components:
  - rails_event_viewer
  - alerts
tags:
  - event-history
  - clock
  - time-current
  - travel-to
  - lookback-window
applies_when:
  - A reader filters rails_event_viewer_entries by occurred_at against Time.current or a passed-in now
  - Specs move time with travel_to around code that writes events
---

# Stamp event occurred_at from the application clock for lookback readers

## Context

`Timekeeping::AlertSignals` counts `Timekeeping::ReconciliationDifferenceFound` and `Timekeeping::FinancialSnapshotChanged` rows in `RailsEventViewer::Entry`. It filters them by `occurred_at` over `(now - SIGNAL_LOOKBACK)..now`, where `now` comes from the application clock.

By default the event carries its own raw system-clock stamp. The two clocks agree in normal running. They split when the application clock is moved, as `travel_to` does in specs. A row then lands outside a window it belongs in, or inside one it does not.

## Solution

Set `occurred_at` from `Time.current` when the adapter writes the event:

```ruby
def write_events(events)
  occurred_at = Time.current
  RailsEventViewer::Entry.transaction(requires_new: true) do
    super(events.map { |event| event.merge(occurred_at:) })
  end
end
```

This is safe only because events are written synchronously (`config.async = false`), so the write time is the event time. If events ever become asynchronous, this stamp would record the write, not the event, and must be revisited.

## Why it matters

A time-window reader is only as correct as the clock its rows were stamped with. If writer and reader use different clocks, boundary specs can pass or fail for the wrong reason, and the window itself is not what the code says. Use one clock, the one the reader compares with. `created_at` already uses it, so `occurred_at` should match.

## Evidence

- PR #196, `config/initializers/rails_event_viewer.rb`: `write_events` merges `occurred_at: Time.current` into each event. Its comment explains the synchronous write and the shared clock with the `timekeeping:alerts` lookback.
- PR #196, `app/services/timekeeping/alert_signals.rb`: `reconciliation_differences` and `financial_snapshot_changes` filter on `occurred_at: lookback(now)`.
- PR #196, `spec/tasks/timekeeping_alerts_5_2_spec.rb`: "prints a financial_snapshot_change alert for a reported snapshot change inside the lookback and none just outside it" reports events under `travel_to` one second either side of `SIGNAL_LOOKBACK` and expects only the inside one to alert.

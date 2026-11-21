---
module: spec/requests/api/v1/timesheet_entries
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - legacy_entry_write_receipts
tags:
  - travel-to
  - flaky-spec
  - receipt-expiry
  - edit-window
applies_when:
  - A spec must cross a calendar-day deadline between two requests
  - The second request must still find a receipt that expires 24 hours after the first
---

# Anchor a deadline-crossing retry at midday inside a 24-hour receipt window

## Context

An employee's delete is allowed only within the company's `timesheet_edit_days` window, which ends at a day boundary. The replay specs must show that a same-key delete retried after that window closes still replays. Legacy write receipts expire after 24 hours (`RETENTION = LegacyCreateReceipt::RETENTION`). Their `expired` scope is `where(expires_at: ..Time.current)`, which includes the expiry moment itself. A retry exactly one day after the first request finds the receipt already expired. A retry at a relative offset from "now" can cross midnight or not, depending on when the test runs.

## Solution

Fix both times to the calendar:

```ruby
midday = Time.current.beginning_of_day + 12.hours
travel_to(midday) { send_request :delete, path, headers: }
travel_to(midday.tomorrow.beginning_of_day + 1.minute) { send_request :delete, path, headers: }
```

The retry lands 12 hours and 1 minute after the first request. That is past the day boundary and well inside the receipt window, at any time of day the suite runs.

## Why it matters

The first version of this spec jumped one day later. It hit the inclusive expiry boundary and failed only some of the time. Any test that pairs a day-based rule with a duration-based expiry has two clocks. Pick times that sit clearly on the intended side of both.

## Evidence

- PR #534 uses this pattern in `spec/requests/api/v1/timesheet_entries/gateway_spec.rb` (contexts "more tests 25" and "more tests 33") and in `spec/requests/api/v1/cli/timesheet_entries/idempotent_replay_spec.rb`. A comment there says a full day later would land on the receipt's expiry boundary.
- `app/models/timekeeping/legacy_entry_write_receipt.rb` defines `scope :expired, -> { where(expires_at: ..Time.current) }`.
- `docs/architecture/timekeeping-soa.md` states that the receipt holds the entry for 24 hours.

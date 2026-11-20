---
module: timekeeping-handoff
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingHandoffOutboxRelay
  - Timekeeping::ProjectionConsumer
tags:
  - fake-relay
  - wire-shape
  - snapshot
  - locked
  - fakes
applies_when:
  - Writing a test fake that converts stored rows into a contract's wire shape before a real consumer reads them
  - Changing TimekeepingHandoffOutboxRelay.wire_entry or wire_value
---

# Send stored values unchanged in a fake wire encoder, except what the real encoder converts

## Context

`TimekeepingHandoffOutboxRelay` turns each stored entry into the snapshot shape that `Timekeeping::ProjectionConsumer` reads. An early version also coerced `locked` to `== true`. That looked like tidying, but it changed the test's meaning. A `nil` lock, which the consumer refuses with 422, became `false` and was accepted with 200. The row was then marked sent.

The real relay converts only time values and passes everything else through. So if the fix for nil legacy locks regressed, a live rollback would stall on a 422, while every runner spec on the fake relay would still pass.

## Solution

In a fake encoder, convert only what the real encoder converts. Here `wire_value` turns times into ISO 8601 UTC text with microseconds and dates into ISO 8601 dates. Every other value goes out as stored:

```ruby
def self.wire_value(value)
  case value
  when ActiveSupport::TimeWithZone, Time, DateTime then value.to_time.utc.iso8601(6)
  when Date then value.iso8601
  else value
  end
end
```

If a correct value must appear on the wire, produce it where the real service produces it. The fake store's `edit_entry!` does this: like the service, it publishes `locked` as whether a reservation holds the entry, not the stored `entries.locked` column.

Pin the pass-through with a spec. Send an otherwise valid snapshot with the bad value, and expect the consumer's refusal.

## Why it matters

A fake that repairs bad data on the way to a real validator removes the validator from the test. The spec then cannot fail where a live run fails. The same risk applies to any field a fake might coerce, such as enums, numbers or missing keys. Only times and dates were checked against the real encoder in this change, so check other encoders before you assume the same split.

## Evidence

- PR #481, `spec/support/timekeeping/handoff_fakes.rb`: `wire_value` converts only time and date values and returns other values unchanged. The `wire_entry` comment says a lock that is not a boolean reaches the consumer and is refused there. `edit_entry!` publishes `locked` from `reserved?(entry)`.
- `spec/contracts/timekeeping/handoff_fakes_spec.rb`, example "the outbox relay sends a nil lock unchanged, so the consumer refuses it with 422 and the projection stays put": `drain!` raises `Undelivered` naming 422, `drained?` stays false, and the projection version does not change.
- When review found the coercion, the author ran this example with the `locked == true` coercion temporarily restored. It failed at the `raise_error(TimekeepingHandoffOutboxRelay::Undelivered, /422/)` expectation, which shows the coercion hid the refusal.

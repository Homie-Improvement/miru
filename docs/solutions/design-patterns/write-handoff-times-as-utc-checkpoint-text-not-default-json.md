---
module: timekeeping_handoff
date: 2026-11-20
problem_type: design_pattern
component: timekeeping_handoff
severity: high
audience: both
related_components:
  - reconciliation
  - correction_snapshots
tags:
  - json
  - timestamps
  - microseconds
  - utc
  - handoff
applies_when:
  - Encoding Time, DateTime or ActiveSupport::TimeWithZone values into JSON that the handoff sends to the other owner
  - Adding a new branch or caller to LosslessSql.json_text
---

# Write handoff times as UTC checkpoint text, not default JSON

## Context

`Timekeeping::Handoff::LosslessSql.json_text` builds the JSON bodies that the handoff sends, including correction snapshots. It already wrote each BigDecimal as a bare number so no value changes on the way. Times, though, fell through to `JSON.generate(value.as_json)`. As the new comment in the encoder says, that default keeps only milliseconds and keeps the value's own time-zone offset.

Both details change the stored value. The receiving `timestamp` column ignores the offset, so a non-UTC time lands as a different instant. Truncating to milliseconds drops the last three digits. Correction snapshots then reach the monolith's `timesheet_entries` projection with changed `created_at` and `updated_at`. The reconciliation projection check compares those fields exactly, so a later rollback is refused.

## Solution

Give times their own branch in `json_text`, before the generic fallback:

```ruby
when Time, DateTime, ActiveSupport::TimeWithZone
  JSON.generate(value.to_time.getutc.strftime(Checkpoint::TIME_FORMAT))
```

This writes the same text the checkpoint already uses: UTC, with nine fractional digits, for example `"2026-01-02T03:04:05.123456000Z"`. The handoff now has one time format on the wire.

Do not fix the refusal by loosening the reconciliation check. A check that rounds or skips timestamps would let a real timestamp change pass a handoff unseen. Fix the writer that changes the value.

## Why it matters

The loss is silent where it happens. The request succeeds, and every other field round-trips. The failure shows up one handoff later, as a projection difference on `updated_at`, and it points away from the encoder. Any new time-bearing payload that goes through `json_text`, or through a similar `as_json` fallback, has the same problem. Test it with a time that has six non-zero microsecond digits and a non-UTC zone.

This rule was checked for the handoff's JSON wire text. It says nothing about other serializers in the app, which may have their own time settings.

## Evidence

- PR #428 adds the time branch and its explanatory comment in `gems/timekeeping_handoff/lib/timekeeping/handoff/lossless_sql.rb`.
- `spec/lib/timekeeping/handoff/lossless_sql_spec.rb` expects `{"t":"2026-01-02T03:04:05.123456000Z"}` for a UTC Time. It also expects a non-UTC TimeWithZone and a `+05:30` DateTime to produce the same UTC text, and BigDecimal, JSON null and nested values to encode as before.
- `spec/lib/timekeeping/handoff/timekeeping_store_spec.rb` checks that `write_correction_snapshots` sends a fixture row's `created_at` and `updated_at` with every microsecond kept.
- `spec/lib/timekeeping/handoff/reconciliation_spec.rb` pins that a projection `updated_at` one microsecond off the checkpoint is still reported as `:changed` and aborts. The check stays strict.

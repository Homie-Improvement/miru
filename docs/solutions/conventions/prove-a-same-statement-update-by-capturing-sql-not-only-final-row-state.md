---
module: timekeeping_handoff
date: 2026-11-18
problem_type: convention
component: timekeeping_handoff
severity: medium
audience: both
related_components:
  - lib/timekeeping/handoff/runner.rb
  - spec/lib/timekeeping/handoff/monolith_admission_spec.rb
tags:
  - rspec
  - active-support-notifications
  - update-all
  - atomicity
applies_when:
  - A requirement says two columns must change in the same update_all, so no moment exists between them
  - Both a one-statement and a two-statement implementation leave the same final row
---

# Prove a same-statement update by capturing the SQL, not only the final row state

## Context

`Runner#close_admission` in `lib/timekeeping/handoff/runner.rb` must clear `admission_fenced_at` in the same `update_all` that sets `handoff_step`. `admission_fenced_at` is the admission fence's mark. While either column is set, `TimekeepingOwnership#admission_closed?` makes monolith writers refuse.

If the change used two statements, there could be a moment between them with both columns open, or a mark left behind after the flip. Either way, the final row would be the same as with one statement: step `"close_admission"`, mark `nil`. A spec that checks only the reloaded row cannot see the difference.

## Solution

Subscribe to `sql.active_record` while the code runs. Collect each `UPDATE` on the table, and assert on the statements themselves:

```ruby
capture = lambda do |_name, _start, _finish, _id, payload|
  sql = payload[:sql].to_s
  ownership_updates << sql if sql.match?(/\AUPDATE\s+"?timekeeping_ownership"?/i)
end
ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { ... }
```

Then find the fence's statement: it writes `admission_fenced_at` but not `handoff_step`. Of the later statements, require exactly one that writes `handoff_step`, and require that it also writes `admission_fenced_at`. Also require that no earlier statement after the fence writes `admission_fenced_at` by itself. Keep the final row checks as well, because they prove the values.

## Why it matters

A "same statement" rule exists to remove a gap in time, and the final row cannot show a gap. Without a check on the statements, a later refactor can split the update, for example into a helper that clears the mark first, and every state-based spec still passes. Counting statements turns the no-gap rule into something a test can fail on.

## Evidence

- In `spec/lib/timekeeping/handoff/monolith_admission_spec.rb`, the example "close_admission clears admission_fenced_at in the same update that sets handoff_step" uses `ActiveSupport::Notifications.subscribed` on `sql.active_record`. It asserts `closing.size` equals 1 and that the closing statement includes `admission_fenced_at`.
- PR #375 changes the `update_all` in `lib/timekeeping/handoff/runner.rb` to pass `admission_fenced_at: nil` beside `handoff_step: "close_admission"`. The comment says admission moves from the mark to `handoff_step` with no moment open between them.

---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping relay
  - Timekeeping::Handoff::RelayDrain
tags:
  - relay-drain
  - catch-up
  - outbox
  - live-specs
  - flaky-tests
applies_when:
  - A live spec waits for the Timekeeping relay to deliver outbox snapshots
  - The runtime's own relay worker runs at the same time as a drain from the spec
---

# Read unsent outbox positions when drained? answers false under the relay lock

## Context

Live Timekeeping specs catch up the relay through the configured drain integration, `Rails.configuration.x.timekeeping_handoff.timekeeping_drain`. Each `drain!(through:)` runs the relay synchronously. A relay run first takes the relay lock. The demo runtime also has its own relay worker, and that worker holds the same lock for its whole run.

While the worker holds the lock, `drain!` returns without sending anything, and `drained?(through:)` answers false. This happens even when the worker has already sent every row. A catch-up loop that trusts only `drained?` therefore fails at random, most often right after a cutover or a resume, when there is a backlog. Its failure message is also misleading: the list of missing positions can be empty, which hides the lock as the cause.

## Solution

After each false `drained?` answer, read the outbox directly and stop when nothing at or below `through` is unsent:

```ruby
attempts.times do
  drain.drain!(through:)
  return nil if drain.drained?(through:)

  unsent = unsent_positions.call(through:)
  return nil if unsent.empty?
end
raise CatchUpIncomplete, "outbox positions #{unsent.inspect} at or below #{through} were still unsent after " \
                         "#{attempts} drain attempts; the runtime's relay worker may have held the relay lock"
```

`unsent_positions` reads `outbox_snapshots` rows with `sent_at IS NULL AND outbox_position <= through`. These are the same rows that `drained?` checks. Keep the attempt count fixed and add no sleep. Read `through` after the writes it must cover. Assert that the entry's own position is at or below `through`, so a baseline target cannot count as catch-up.

## Why it matters

A false `drained?` answer means only that this drain did not confirm delivery. It does not mean the rows are unsent. Treating the two as the same makes live specs flaky whenever a background worker shares the lock. Reading the rows that `drained?` would read gives the same answer without depending on who held the lock. The failure message names the lock, so a real timeout points at the right cause.

## Evidence

- PR #536 adds `catch_up!` and the comment on `CATCH_UP_ATTEMPTS` in `spec/support/timekeeping/live_handoff_helpers.rb`. The comment states that drain answers false whenever the runtime's relay worker holds the relay lock, even after that worker has sent every row.
- `spec/meta/timekeeping_live_handoff_helpers_spec.rb` has the example "returns once no position at or below through is unsent, though drained? never answers true". It returns after two attempts. Another example in that file checks the bounded failure message, the three `drain!` calls and that `sleep` is never called.
- `spec/integration/timekeeping/relay_paused_spec.rb` reads `through` from `Timekeeping::Handoff::TimekeepingStore.new.highest_outbox_position` after the entry exists. It then asserts `outbox_rows.map(&:first).max` is at or below it before calling `live_handoff_catch_up!(through:)`.

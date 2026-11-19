---
module: timekeeping
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::Handoff::Drain
  - RelayJob
tags:
  - handoff-drain
  - advisory-lock
  - relay
  - mutation-check
  - spec-design
applies_when:
  - Writing or trimming a spec that asserts the drain answer while another connection holds RelayJob::RELAY_LOCK_KEY
  - Removing duplicate drain examples and keeping a check that the answer changes after the lock is released
---

# Mark every row at or below `through` as sent when testing the drain lock

## Context

`Timekeeping::Handoff::Drain.call(through:)` answers `drained`. It is false for two separate reasons:

- an `outbox_snapshots` row at or below `through` still has `sent_at` NULL, or
- the relay skipped its run because another connection holds the relay advisory lock (`RelayJob::RELAY_LOCK_KEY`).

A spec for the second reason fails to test it when its input also triggers the first reason. Suppose any row at or below `through` is unsent. Then the answer is false with the lock check or without it. The spec stays green if someone deletes the lock check. This came up in review of PR #386, where the two sides disagreed on whether a lock example could catch a broken lock path. The answer turned on where the unsent row sat relative to `through`.

## Solution

In a lock example, mark every row at or below `through` as sent before taking the lock. Then the only possible cause of a false answer is the skipped relay. An unsent row above `through` is fine, because the drain rule ignores it.

When an example proves the answer becomes true after the lock is released, keep its held-lock step:

1. Mark the rows at or below `through` as sent.
2. Have a second connection take `pg_advisory_lock(RELAY_LOCK_KEY)`.
3. Assert `call(through:)` is false.
4. Close that connection.
5. Assert `call(through:)` is true.

Step 3 is not a duplicate of the contention spec, even when another spec owns contention. Without it, a true answer after release does not show any change.

To confirm a lock example really tests the lock, make the drain answer ignore whether the relay ran. Do this in a scratch copy and restore it after. The example must fail. If it still passes, some unsent row at or below `through` is producing the false answer.

## Why it matters

The answer is a single boolean with two causes, so a test can pass for the wrong cause. Specs that build rows by hand often leave one row unsent by accident, or on purpose to show that nothing was delivered. That hides the lock path. Trimming duplicates makes this worse. The author may delete the held-lock step as "already covered", which leaves a release check that would pass even if the lock never mattered.

## Evidence

- PR #386 edits `timekeeping/spec/services/timekeeping/handoff/drain_spec.rb`. The kept lock example inserts rows at positions 1 and 2, then runs `OutboxSnapshot.update_all(sent_at: Time.current)`. Every row at or below `through: 2` is sent before `other_connection.exec_params("SELECT pg_advisory_lock($1)", [RelayJob::RELAY_LOCK_KEY])`. The example then expects `described_class.call(through: 2)` to be false under the lock and true after `other_connection.close`.
- The same file's comments state both causes. The kept comment says `drained` is true only when no `outbox_snapshots` row with position at or below P has `sent_at` NULL. The comment this PR removes says a relay that skipped on its advisory lock leaves `drained` false.
- PR #386 adds a comment to the lock example. It says the example observes the held-lock false answer only so that the true answer after release shows a change. That is the reason for keeping step 3 above.
- PR #386's description reports a scratch run where dropping the lock check failed both the request lock example and this service release example.
- Verification step, not evidence from this change: in `timekeeping/spec/requests/internal/v1/handoff/drains_spec.rb`, confirm that the lock example's unsent row sits above `through`, not at or below it.

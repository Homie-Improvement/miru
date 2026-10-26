---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "timekeeping/spec/services/timekeeping/reservation_operations_spec.rb in PR #181 builds the commit refusal by committing a reservation over two entries, preparing a second operation over only one, and corrupting the left-out entry so commit releases it; the abort refusal corrupts the operation's own provisional entry"
audience: both
related_components:
  - reservation_operations
  - outbox
tags:
  - rspec
  - reservations
  - locked-flag
  - outbox
  - test-reachability
applies_when:
  - Writing a spec that proves a check inside WriteSteps.write_outbox runs on a reservation prepare, commit or abort
  - Reviewing a reservation spec that corrupts an entry and expects a refusal
---

# Flip the locked flag to reach the outbox in reservation specs

## Context

`ReservationOperations` publishes an outbox snapshot only for entries whose `locked` flag flips. `record_locked_flips` returns before `write_outbox` when no flag changes.

A normal commit turns a provisional reservation into a committed one. The entry was locked before and stays locked, so nothing is published. A spec that prepares, corrupts the entry, and commits never reaches any check inside `write_outbox`. It can pass for the wrong reason, or fail in a way that has nothing to do with the check.

## Solution

Arrange each reservation spec so the bad entry's `locked` flag actually changes:

- **Prepare**: corrupt an entry before prepare. Prepare locks it, so it reaches the outbox.
- **Commit**: commit an operation over two entries. Then prepare a second operation over only one of them, and corrupt the one left out. The second commit releases that entry, which unlocks it and republishes its row.
- **Abort**: prepare, then corrupt the operation's own provisional entry. Abort unlocks it.

Keep a separate spec that a commit with no flag change still succeeds and writes no outbox row. That spec pins the no-flip path, so a change that starts publishing on every commit is caught.

## Why it matters

A spec that never reaches the guard gives false confidence. It stays green if the guard is removed. Plan each case from the flag change, not from the route name.

The commit case also shows the recovery rule. When only a released entry is bad, the commit is refused but abort still works. Abort flips only the operation's own provisional entries, so the invoice service can still cancel.

## Evidence

- PR #181, `timekeeping/spec/services/timekeeping/reservation_operations_spec.rb`: the commit refusal spec commits over `kept_entry` and `released_entry`, prepares a second operation over `kept_entry` only, sets `released_entry`'s `source` to `"legacy"`, and expects a 409 naming `released_entry`. The abort of that operation then answers 200.
- The same file: the abort refusal spec sets `source` to `"legacy"` on the operation's own provisional entry after prepare, and expects a 409 with the provisional reservation and prepared state restored.
- The same file: the prepare refusal spec sets `review_status` to `"unknown"` before prepare and expects no `InvoiceOperation` row.
- `timekeeping/app/services/timekeeping/reservation_operations.rb`: the new rescue says the refusal comes from a flipped entry's stored row.

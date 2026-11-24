---
module: timekeeping
date: 2026-11-24
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - database
  - testing_framework
tags:
  - postgresql
  - row-locks
  - foreign-keys
  - key-share
  - local-owner
  - reservations
applies_when:
  - An entry update or delete must be refused when a reservation for that entry is being inserted in another transaction
  - Someone proposes removing a `FOR UPDATE` on a parent row because the child table already has a foreign key to it
---

# Take FOR UPDATE on the entry so an update waits for an uncommitted reservation insert

## Context

An employee update to a time entry must not slip past a reservation that is being inserted for that entry. If the reservation commits, the update must be refused. If it rolls back, the update may go ahead.

The reservations table has a foreign key to entries, so it is easy to assume the database already makes the two writes take turns. It does not. When a session inserts a reservation, it takes only a key-share lock on the entry row it references. A plain UPDATE that does not change the entry's key does not conflict with that lock. So without an explicit lock, the update runs straight through while the reservation is still uncommitted.

## Solution

On the entry update and delete path, lock the entry rows with `FOR UPDATE` before reading or changing them. `LocalOwner#locked_entries` in `app/services/timekeeping/local_owner.rb` does this with `relation.order(:id).lock("FOR UPDATE").pluck(:id)`. `FOR UPDATE` conflicts with the key-share lock that the uncommitted insert holds. The update then waits until the reservation commits or rolls back, and re-reads the entry afterwards.

Keep this lock even though the foreign key exists. The foreign key keeps the data valid. It does not order the two transactions.

When you test this, check the waiter's answer and that it waited. Pair a commit case (the update is refused) with a rollback control (the update changes the entry). Both should fail when the lock is removed.

## Why it matters

If the lock is removed, an entry can be edited while it is being reserved for an invoice. The reservation then commits against hours that no longer match what was billed. Nothing raises an error, so the race shows up only as wrong data later.

## Evidence

PR #625 adds a **Local-owner entry row lock** subsection to `docs/solutions/conventions/identify-the-lock-a-session-waits-on-not-only-that-it-is-blocked.md`. In that run, `.lock("FOR UPDATE")` was removed from `LocalOwner#locked_entries` in `app/services/timekeeping/local_owner.rb`. Two examples in `spec/services/timekeeping/local_owner_concurrency_spec.rb` (lines 167 and 202) then failed: "refuses an employee update that waited on the row lock behind a reservation insert that then commits" and its rolled-back control. Each failed with "the update never waited on the reservation insert's lock on the entry row". The record explains that the reservation INSERT holds only a key-share lock on the entry, and that without the `FOR UPDATE` the update's own row lock does not conflict with it. The lock was restored afterwards, and the pull request reports the five spec files passing on the restored tree.

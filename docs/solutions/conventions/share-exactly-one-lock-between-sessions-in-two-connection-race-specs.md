---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - Timekeeping::LocalOwner
  - reservations
  - TimekeepingOwnership
tags:
  - concurrency
  - row-lock
  - foreign-key
  - blocked-by
applies_when:
  - Writing a committed_data two-connection spec that proves one specific lock
  - The service under test takes several locks in one transaction
---

# Share exactly one lock between the sessions in a two-connection race spec

## Context

`blocked_by?(waiting_pid, holding_pid)` says that one backend waits on another. It does not say which lock it waits on. `Timekeeping::LocalOwner` takes several locks in one call: a `FOR SHARE` read of the ownership row, an advisory lock on the idempotency key, a `FOR UPDATE` lock on the entry rows, and the outbox advisory lock. If two racing sessions share more than one of these, the example still sees a wait after the lock under test is removed.

## Solution

Design each race so the lock under test is the only lock both sessions need:

- **Outbox lock:** the two writers update different entries with different idempotency keys. Their key locks and row locks differ, and two `FOR SHARE` reads of the ownership row do not conflict.
- **Ownership lock during a handoff:** the competing session is a plain `update_all(handoff_step: "close_admission")` on the ownership row, not a second LocalOwner call.
- **Entry row lock:** hold the entry with a raw, uncommitted `INSERT INTO reservations` on another connection. The foreign key from `reservations` to `entries` makes the insert lock the referenced entry row in key-share mode, which a `FOR UPDATE` must wait for. The insert takes no receipt or ownership lock.

Write a comment above each example that names the single shared lock, so a reviewer can check it.

## Why it matters

The whole point of these specs is to fail when someone drops a lock. If a second shared lock also produces the wait, the spec stays green and the regression ships. Keeping one shared lock makes the `blocked_by?` check point at one lock only.

## Evidence

- PR #185 adds `spec/services/timekeeping/local_owner_concurrency_spec.rb`. The comment on the outbox example says the writers update different entries with different keys, so the outbox lock is the only lock they share.
- The comment on `hold_reservation_insert` in the same file says the foreign key from reservations to entries makes the insert hold a key-share lock on the entry row, which a `FOR UPDATE` row lock must wait for. That this conflict holds is PostgreSQL behaviour the comment asserts; the diff does not show the foreign key itself, which is why this document is graded speculative.
- The handoff example uses `TimekeepingOwnership.where(...).update_all(handoff_step: "close_admission")` as the competing session, and its comment says the writer's share lock on the ownership row is the only one the handoff needs.
- The PR #185 description reports that removing each lock in a scratch edit made its example fail; that run is reported, not shown in the diff.

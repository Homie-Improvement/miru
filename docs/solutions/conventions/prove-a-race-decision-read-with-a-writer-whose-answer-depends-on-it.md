---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb in PR #112: the comment above the new bulk-delete race says its audit row and snapshot come from a read made after the delete, so it proves the stored outcome, not the reservation flag the delete decision saw, and names the refused-update example as the check for that."
audience: both
related_components:
  - reservation_operations
  - entry_writer
tags:
  - race-condition
  - two-connection-test
  - stale-read
  - audit-events
  - outbox-snapshots
applies_when:
  - Writing a two-connection race test where one writer waits on another's row lock
  - The waiting writer builds its audit row or snapshot from a fresh read after applying its change
  - The waiting writer's rule ignores the fact the held operation just changed
---

# Prove a race decision's read with a writer whose answer depends on it

## Context

A race test holds one operation at its row-lock step and lets a second writer wait on that lock. The goal is often to prove that the waiting writer, once released, decides on the facts as the held operation left them. Those facts are read after the lock wait, not before it.

It is easy to believe that strong final-state checks prove this. These are checks on entry version, audit rows and outbox snapshots, which are the rows other readers consume. They do not prove it when two things are both true:

- The writer re-reads the rows after applying its change, and that fresh read feeds the audit row and the snapshot.
- The writer's rule does not depend on the contested fact. In the timekeeping rules, the A6 reservation rule does not bind deletes. That exception is called A10.

Under those conditions, a decision that read stale facts and one that read fresh facts leave the same stored trail. The test passes either way.

## Solution

Use two kinds of race example, and say in each one what it proves.

1. **The discriminating example.** Race the held operation against a writer whose *answer* changes with the contested fact. In the timekeeping race spec, this is an employee update that waits on a prepare. A6 refuses the update only if the update reads the new reservation, so a `403` proves the read happened after the lock wait. A stale read would return `200` instead.
2. **The stored-outcome example.** Race against writers that ignore the fact, such as the bulk delete under A10. Assert the serialized trail in order:
   - versions 1 → 2 (prepare) → 3 (delete);
   - audit actions `prepare` then `bulk_delete`;
   - each snapshot's version, discarded flag and locked flag.

   In the example's comment, say plainly that it proves the stored outcome and not the decision's read. Name the example that does prove the read.

Do not remove the discriminating example because a newer example "checks more fields". The newer example may check more fields yet still not be able to fail for a stale read.

## Why it matters

If every race example uses a writer that ignores the contested fact, a regression can go unnoticed. A writer might start reading reservation facts before taking its row locks. It would then decide on stale data, yet the suite would stay green. The post-change re-read hides the stale read in the audit row and snapshot.

The fix costs one example per writer path. Each example needs a writer whose response depends on the fact.

This was seen on the timekeeping entry writer, with reservations as the contested fact. It applies to another writer only when that writer also rebuilds its audit row or snapshot from a later read. Check that before you rely on a stored-outcome example there.

## Evidence

- PR #112, head commit de541d739f277c19ffdee7fbdac381a43910b6b3. This change edits `timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb`.
- The new example "discards a reserved entry when an employee bulk delete waited on its prepare" has a comment that says three things:
  - A6 does not bind deletes (A10).
  - The audit row and snapshot come from a read made after the delete.
  - The example therefore proves the serialized stored outcome, not which reservation flag the delete decision saw. The update example above it is the check for that.
- That example asserts the bulk delete answers `200` with result `"deleted"`. It then asserts version `seeded_version + 2`, audit actions `%w[prepare bulk_delete]`, and snapshots `[[seeded_version + 1, false, true], [seeded_version + 2, true, true]]`.
- The example "refuses an employee update that waited on a prepare of the same entry" asserts the statuses `[200, 403]`. The update's answer depends on the reservation it read after waiting.

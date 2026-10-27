---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/services/timekeeping/local_owner_concurrency_spec.rb, outbox example: its comment says position order alone would read [first, second] even without the lock, and it asserts blocked_by? and committed_row_count('entry_outbox_items') == 0 while the first writer is paused at :outbox_written"
audience: both
related_components:
  - Timekeeping::LocalOwner
  - entry_outbox_items
tags:
  - concurrency
  - advisory-lock
  - outbox
  - committed-data
applies_when:
  - Testing that a lock makes concurrent writers commit their outbox rows in order
  - The ordering value (a sequence or position) is taken before the point where the test pauses the first writer
---

# Prove commit order with a blocked writer and an uncommitted row, not with the final order

## Context

`Timekeeping::LocalOwner` takes `pg_advisory_xact_lock` on a fixed outbox key before it writes an outbox row. The lock stops a second writer from committing its outbox row while an earlier writer is still open. A relay that reads rows by position could otherwise skip a gap that fills in later.

The obvious test runs two writers and checks that `outbox_position` orders the first entry before the second. That test passes with the lock deleted. The first writer draws its position before it pauses at `:outbox_written`. Without the lock, the second writer still draws a higher position, so the final order is the same.

## Solution

Assert the proof while the first writer is still paused:

1. Pause the first writer at a step after it takes the lock (`:outbox_written`).
2. Start the second writer on a different entry.
3. Check `blocked_by?(second_pid, first_pid)` is true.
4. Check that no `entry_outbox_items` row is committed yet.
5. Release the first writer in `ensure`. Then check both answers are 200 and the final order.

The final order is still worth asserting, but only as a last check. The wait and the missing committed row are what fail when the lock goes away.

## Why it matters

An order-only assertion gives a green test that protects nothing. A later change that drops the outbox lock would ship with the spec still passing. Commit order is about what is visible while a transaction is open, so the test must look while it is open.

## Evidence

- PR #185 adds `spec/services/timekeeping/local_owner_concurrency_spec.rb`. Its example "holds a second writer's outbox row back until a first writer paused after its outbox insert commits" records `blocked` and `committed_while_paused` before it releases the first writer, and asserts `committed_while_paused` is 0.
- The comment above that example states that position order alone would read `[first, second]` even without the lock.
- The PR #185 description reports that removing the outbox lock in a scratch edit made this example fail. That run is reported by the author, not shown in the diff.

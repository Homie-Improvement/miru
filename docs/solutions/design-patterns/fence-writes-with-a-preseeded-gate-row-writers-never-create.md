---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: timekeeping
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #64 at 5861233043a39cb98e88d8ff643ddd7dfb6ad814, timekeeping/app/services/timekeeping/entry_writer.rb drops the INSERT ... ON CONFLICT DO NOTHING seed and only reads Admission.locked_generation. timekeeping/app/models/timekeeping/admission.rb fence! runs SET LOCAL lock_timeout and an UPDATE inside one transaction. entry_writer_race_spec.rb shows the fence blocked by an admitted write, and shows a 0.2 s timeout leaving generation 1 and lock_timeout back at 0."
audience: both
related_components:
  - entry_writer
  - database
tags:
  - fencing
  - ownership-handoff
  - for-share
  - lock-timeout
  - fail-closed
  - singleton-row
applies_when:
  - A service must stop accepting writes at a cutover point, such as an ownership handoff or a checkpoint
  - Writers check a stored generation or gate value before they change data
  - A gate row would otherwise be created on demand by the write path
---

# Fence writes with a gate row that is created ahead of time and that writers never create

## Context

Timekeeping must stop accepting entry writes once an ownership handoff takes its checkpoint. Before PR #64, `EntryWriter#locked_generation` ran `INSERT INTO ownership_generations ... VALUES (?, 1) ON CONFLICT (company_id) DO NOTHING` and then read the company's row FOR SHARE. This fence could not hold. Setting every existing row to "fenced" did not cover a company with no row yet. That company's first write created its row at generation 1 and was admitted.

The general trap: if the write path creates its own gate row, any key the fence never saw passes the fence. So does any write that runs after the row is lost.

## Solution

PR #64 does the following:

- **One gate row, created ahead of time.** The `admission` table holds one row. A check constraint (`id = 1`) allows only that row, and its `generation` column can be null. A null generation means fenced. The migration inserts this row. Databases loaded from `db/schema.rb` get it from `db/seeds.rb`, from a `before(:suite)` hook, and from the hook that runs after each non-transactional example. All of these call `Timekeeping::Admission.ensure_initial!`.
- **Writers only read the row.** `Admission.locked_generation` runs `SELECT generation FROM admission WHERE id = ? FOR SHARE`. A missing row and a fenced row both read as `nil`. `nil` matches no header, so the write is refused with `stale_generation`. Nothing on the write path inserts the row.
- **The fence waits for writes already admitted.** `fence!` opens its own transaction, runs `SET LOCAL lock_timeout`, and then runs a plain `UPDATE ... SET generation = NULL`. The UPDATE's row lock conflicts with FOR SHARE. So the fence waits until every write that has already read the generation commits.
- **A timeout rolls back.** When the lock wait passes the timeout, PostgreSQL raises an error, which Rails surfaces as `ActiveRecord::LockWaitTimeout`. The transaction rolls back and the generation is unchanged, so the caller knows the fence did not take effect. `SET LOCAL` ends with the transaction, so the short timeout never stays on a pooled connection.
- **Changes to the row never create it.** `fence!` and `admit!` raise `RecordNotFound` when the row is missing. `admit!` also rejects any value that is not a positive Integer. Without that check, `admit!(generation: nil)` would fence writes without anyone announcing it.

## Why it matters

A fence that creating on demand can get around is not a fence. The bug never shows in tests that only check companies with rows. It only shows for a company the fence never saw, or after the row is lost, and that is exactly when a handoff needs the fence most.

Read the row FOR SHARE and let the fence UPDATE it. That makes "the fence returned" mean "no admitted write is still in flight". Use `SET LOCAL` rather than `SET`, inside a transaction. That way a fence that gives up leaves both the state and the connection as they were, and the handoff can stop or retry.

Pick your fallback with care. Creating the row on demand fails open. Refusing fails closed. A gate should fail closed and rely on seeding to supply the row.

## Evidence

All from PR #64 at head commit 5861233043a39cb98e88d8ff643ddd7dfb6ad814:

- `timekeeping/app/services/timekeeping/entry_writer.rb`: removes the per-company `INSERT ... ON CONFLICT DO NOTHING` from `locked_generation`, which now calls `Admission.locked_generation`.
- `timekeeping/app/models/timekeeping/admission.rb`: `locked_generation` (a FOR SHARE read), `fence!` (`SET LOCAL lock_timeout` plus an UPDATE in one transaction, with `FENCE_LOCK_TIMEOUT = 60.seconds`), the positive-Integer guard on `admit!`, and `set_generation`, which raises `RecordNotFound` when no row was updated.
- `timekeeping/db/migrate/20260501000000_replace_ownership_generations_with_admission.rb`: creates the row with the `admission_single_row_check` constraint and seeds it from `COALESCE(MAX(generation), 1)`.
- `timekeeping/db/seeds.rb` and `timekeeping/spec/rails_helper.rb`: call `ensure_initial!` for databases loaded from schema.
- `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb`: "makes a fence wait until the write that read the admitted generation commits" checks that the generation is still 1 while the fence waits. The timeout example checks that `fence!(lock_timeout: 0.2)` raises `ActiveRecord::LockWaitTimeout`, leaves the generation at 1, and leaves `SHOW lock_timeout` at `0`.
- `timekeeping/spec/services/timekeeping/entry_writer_admission_spec.rb`: while fenced, refuses writes for a company never seen before. Also refuses writes when the admission row is missing, and the row is never recreated.

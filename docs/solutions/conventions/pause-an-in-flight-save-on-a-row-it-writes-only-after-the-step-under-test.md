---
module: timekeeping handoff specs
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - billing
  - timekeeping
tags:
  - concurrency
  - row-lock
  - blocked-by
  - committed-data
  - handoff
applies_when:
  - A spec must hold a real write partway through, so another process can be shown waiting on it
  - The proof is a lock wait read with blocked_by? or pg_blocking_pids
---

# Pause an in-flight save on a row it writes only after the step under test

## Context

Some concurrency specs need a real save stopped at a known point. For example, an invoice save must be stopped after its reservation is prepared, while its billing fence still holds the ownership row `FOR SHARE`. Then the spec can show a rollback's step 1 waiting on that save. If the save stops at the wrong point, the wait still shows up, but it proves something else. A save stopped too early may not hold the share lock yet.

## Solution

- Choose a row that the save writes only **after** the step you need finished. For an invoice save, that row is the invoice's `invoice_entry_holdings` row. The coordinator's settle writes it only after `reservations.prepare` returns.
- Do not lock a row the save creates itself, such as its intent row. The save inserts that row inside its own transaction, so a lock taken before the save starts has nothing to lock. A lock taken after it starts races the save.
- Before the save starts, take the row `FOR UPDATE` in a transaction on a session opened outside the pool, with `ActiveRecord::Base.connection_pool.db_config.new_connection`.
- Assert `blocked_by?(save_pid, holder_pid)` **before** you start the competing process, such as the rollback. Only then assert `blocked_by?(runner_pid, save_pid)`. If you check in the other order, a wait could come from the wrong holder.
- To end the pause, disconnect the holder session.

## Why it matters

A lock-wait assertion proves only what the paused state really holds. If the pause row is chosen well, removing the `FOR SHARE` read in the billing fence makes the step-1 assertion fail. If the pause row is chosen badly, the assertion can pass for a reason that has nothing to do with the fence.

## Evidence

- PR #537 adds `spec/integration/timekeeping/handoff_concurrency_spec.rb`. Its helper `concurrency_hold_holding_row` opens a session with `db_config.new_connection` and runs `SELECT 1 FROM invoice_entry_holdings ... FOR UPDATE`. The helper's comment says the save writes that row in `Invoices::OperationCoordinator#settle` only after `reservations.prepare` returns.
- In the in-flight example, `blocked_by?(save_pid, holder_pid, ...)` is asserted before `concurrency_rollback_thread` starts. After that comes `blocked_by?(runner_pid, save_pid, ...)`, with the message "step 1 of the rollback did not wait on the save's FOR SHARE lock".
- The PR #537 description records that removing the `FOR SHARE` read in `BillingFence.admit!` failed with exactly that message.

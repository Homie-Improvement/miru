---
module: timekeeping_handoff
date: 2026-11-14
problem_type: design_pattern
component: timekeeping_handoff
severity: high
audience: both
related_components:
  - database
tags:
  - checkpoint
  - table-store
  - local-columns
  - row-filter
  - shape-error
applies_when:
  - A checkpoint store's table holds rows or columns the checkpoint does not carry
  - A load deletes and replaces a table's rows from a checkpoint
---

# Apply one checkpoint row condition to export, the load DELETE and the read-back

## Context

`TableStore` exports whole tables into a checkpoint and loads a checkpoint by deleting each table and inserting its rows. It then reads the tables back and checks them against the checkpoint. This PR let `idempotency_records` hold service receipts, which the checkpoint does not carry, plus an `actor_name` column the checkpoint has no place for.

Filtering only the export is not enough. An unfiltered `DELETE FROM` erases the service receipts on every load. An unfiltered read-back sees the kept rows, so the stored state never matches the checkpoint and every load fails. And `check_columns!` refuses any column outside `Checkpoint::TABLES`.

## Solution

Give the store hooks that default to no-ops, so stores that hold only checkpoint rows are unchanged:

- `local_columns(table)`: columns the store keeps that the checkpoint does not carry. `check_columns!` leaves them out of the unknown list.
- `checkpoint_rows_condition(table)`: a SQL condition naming the checkpoint's rows. One helper, `checkpoint_rows_where`, adds it to both the load `DELETE` and `read_rows`. The read-back after a load also goes through `read_rows`, so all three see the same rows.
- `before_insert(table, rows)`: runs in the load transaction to make room for incoming rows among the kept ones.

After reading, `without_local_columns` raises `Checkpoint::ShapeError` if a checkpoint row holds a value in a local column, then drops those keys. `MonolithStore` names the column (`actor_name`) and the condition (`actor_type <> 'service'`).

## Why it matters

One helper feeding every read and delete keeps the three steps from drifting apart. The non-null check is what makes dropping a local column safe. A user receipt that somehow carries `actor_name` makes export fail loudly instead of losing the value in the checkpoint.

A consequence to state when you use this: rows kept outside the checkpoint do not travel across a cutover.

## Evidence

- PR #261, `gems/timekeeping_handoff/lib/timekeeping/handoff/table_store.rb`: adds `local_columns`, `checkpoint_rows_condition`, `before_insert` and `checkpoint_rows_where`; the load `DELETE` and the `SELECT` in `read_rows` both append `checkpoint_rows_where(table)`; `check_columns!` subtracts `local_columns(table)`; `without_local_columns` raises `Checkpoint::ShapeError` for a filled local column.
- PR #261, `lib/timekeeping/handoff/monolith_store.rb`: overrides the hooks for `idempotency_records` with `RECEIPT_LOCAL_COLUMNS = %w[actor_name]` and `USER_RECEIPTS_CONDITION = "actor_type <> 'service'"`.
- PR #261, `spec/lib/timekeeping/handoff/monolith_store_spec.rb`: loading the same checkpoint twice keeps one copy of the service receipt and the export digest equals the checkpoint's; export with only a service receipt holds no rows; a user receipt carrying `actor_name` makes export raise `ShapeError`.

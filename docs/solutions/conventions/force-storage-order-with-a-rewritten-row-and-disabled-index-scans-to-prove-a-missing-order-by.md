---
module: invoices
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - service_layer
  - database
tags:
  - postgres
  - order-by
  - heap-order
  - flaky-spec
  - relation-update-bang
  - parallel-tests
applies_when:
  - A service loads rows and saves them one by one, for example with Relation#update!, and a validation failure partway through decides which rows were saved
  - A spec passes when its file runs alone but fails under bin/parallel_test
  - You need a regression spec that fails on code with no ORDER BY, not just one that passes on the fixed code
---

# Force storage order with a rewritten row and disabled index scans to prove a missing ORDER BY

## Context

`Relation#update!` in Rails does not send one UPDATE. It loads the matching rows and saves each record in the order the load returned them. With no `ORDER BY`, Postgres decides that order, and with a sequential scan it returns rows in the order they are physically stored. When one record fails validation, the records saved before it depend on that storage order.

`Invoices::LegacyReservations#mark_billed` billed entries this way. Its spec expected the lower-id valid entry to be updated before the invalid entry raised `RecordInvalid`. Run alone, the spec passed. Under the parallel suite, other examples left free space in the table. The invalid entry's newer row version could then be stored, and returned, first. Validation raised before any UPDATE ran, and the spec saw `Expected [] to eq ["legacy_gateway"]`. The problem was the service's undefined save order, not the spec.

## Solution

Fix the order at its source: add `.order(:id)` to the relation that `update!` saves, so the save order is the same on every run. In this code it also matches the order `lock_entries` takes row locks in.

Then write a spec that fails on the unordered code every time:

1. Create the valid, lower-id row first, then the invalid row.
2. Rewrite the lower-id row with `update_columns` (here, its `note`). Postgres stores a new row version, which a sequential scan reaches after the invalid row.
3. Inside the transaction, run `SET LOCAL enable_indexscan = off` and `SET LOCAL enable_bitmapscan = off`. Without this step the planner may pick a primary-key index scan, which returns rows in id order even with no `ORDER BY`. The spec would then pass on the broken code.
4. Pass the ids in reverse order, and assert that the valid row was saved before `RecordInvalid` names the invalid row.

Also add a check that does not depend on how rows are stored. Subscribe to `sql.active_record`, collect the `SELECT "timesheet_entries".*` statements that are not `FOR UPDATE`, and assert that each one includes `ORDER BY "timesheet_entries"."id"`.

An example that bills only valid rows proves nothing about order, because every row gets saved whatever order the load returns. Give it a title that says what it actually checks.

## Why it matters

A spec that only passes on the fixed code leaves the fix unproven. Reordering rows without turning off index scans proves no more, because the planner can hide the bug. Turning off the index and bitmap scans makes the failing case happen on every run, so a later edit that drops `.order(:id)` fails in a single run of the spec file, not now and then in CI. The SQL check still holds if the planner or the storage layout changes.

## Evidence

- PR #495 changes `app/services/invoices/legacy_reservations.rb` from `TimesheetEntry.kept.where(id: entry_ids).update!(bill_status: :billed)` to the same relation with `.order(:id)`. Its new comment says `update!` saves the rows one by one in load order.
- In the same pull request, `spec/services/invoices/legacy_reservations_spec.rb` adds the example that rewrites `valid_entry` with `update_columns`, runs the two `SET LOCAL ... = off` statements, requests `[invalid_entry.id, valid_entry.id]`, and expects `marks` to equal `["legacy_gateway"]`. It also adds the example that asserts every captured load includes `ORDER BY "timesheet_entries"."id"`.
- The review of PR #495 found that, before the scans were turned off, the reordering example could pass on unordered code under an index scan. With the scans off and the old service restored, the author's runs failed 3 of 3 times with `Expected [] to eq ["legacy_gateway"]`. With the fixed service, the spec file and `spec/services/timekeeping/legacy_writer_mark_spec.rb` ran 34 examples with 0 failures.
- The review also found that the example billing two valid entries passes with or without `.order(:id)`, so it was renamed to describe the writer-mark coverage it actually provides.
- Issue #459 records the CI failure at `legacy_reservations_spec.rb:906` under the parallel run, while running the file alone gave 0 failures on each of three runs.

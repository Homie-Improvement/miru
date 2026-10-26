---
module: Timekeeping::Handoff::Reconciliation
date: 2026-10-26
problem_type: design_pattern
component: timekeeping_handoff
severity: high
evidence_grounding: anchored
grounding_evidence: lib/timekeeping/handoff/reconciliation.rb Correction#explains? compares check, row_key and field and returns false for :duplicate_key; specs in reconciliation_spec.rb prove a locked correction does not excuse a duration change, an operation-row correction does not excuse the intent-row change, and a listed added reservation does not excuse its duplicate
audience: both
related_components:
  - timekeeping_handoff
tags:
  - reconciliation
  - allow-list
  - corrections
  - duplicate-key
  - handoff
applies_when:
  - A comparison reports differences and a caller-supplied list of expected corrections turns some of them into passes
  - Two tables are compared under one check name
  - Rows are grouped by key and one side may hold the same key twice
---

# Match a listed correction to one exact difference, and never to a duplicate

## Context

Handoff reconciliation compares a loaded checkpoint with the frozen source. Any difference aborts the handoff unless the pre-flight listed it as an expected correction for that company. The list is an allow-list: each entry turns one difference into a pass.

The first design matched a correction by company, check and row key only. One approved change on a row then excused every other change on that row. For example, a listed `locked` correction also hid a changed `duration`, which is billable time. Two more forms of the same hole appeared later. An `invoice_id` correction on an `invoice_operations` row also excused the same change on its `invoice_operation_intents` row, because both used check `:operation_receipts` and the same row key. A listed "row added" correction also hid a second committed reservation for the same entry, because the comparison returned "missing in source" before it looked for duplicates.

## Solution

- A correction names the check, the row key **and the field**. `Correction#explains?` in `lib/timekeeping/handoff/reconciliation.rb` requires all three to be equal. A nil field matches only a whole-row difference.
- No correction explains a `:duplicate_key` difference. The pre-flight lists single rows, so two rows under one key are never one approved change.
- `compare_rows` reports a duplicate key on either side *in addition to* a missing counterpart, not instead of it. A key that exists on one side only, and twice on that side, yields both differences.
- Two tables under one check get row keys of different shapes. Operation rows use `[id]` (`OPERATION_KEY`). Intent rows use `[invoice_id, operation_id]` (`RECEIPT_LINK_KEY`). `Correction` has no table field, so these different key shapes are the only thing that stops a correction for one table matching a difference in the other. If you add a check that compares two tables whose keys could share a shape, add the table to `Correction` instead.

## Why it matters

An allow-list that matches too broadly fails silently. The run passes, the report looks clean, and the operator approves a handoff with a change nobody listed. Tests that change one field at a time cannot catch this. Each one needs a second, unlisted change on the same row (or a second copy of the row) next to the listed one.

The narrow match has a cost: the pre-flight must list one correction per field. That cost is cheap. A broad match makes a wrong approval impossible to see.

## Evidence

PR #92, head commit 23fd205128e594c79c537a6f660c31934c92f3e2.

- `lib/timekeeping/handoff/reconciliation.rb`: `Correction#explains?` returns false when `difference.reason == :duplicate_key`, and otherwise compares `check`, `row_key` and `field`. `compare_rows` builds the `duplicate` list before it returns on a missing side. `OPERATION_KEY` and `RECEIPT_LINK_KEY` give operation and intent rows different key shapes.
- `spec/lib/timekeeping/handoff/reconciliation_spec.rb`, "lets a listed correction pass only for its own company, row and field": a `locked` correction passes, but a `duration` change on the same row still aborts.
- `spec/lib/timekeeping/handoff/reconciliation_spec.rb`, "does not let an entries correction for one field excuse a changed note on the same entry".
- `spec/lib/timekeeping/handoff/reconciliation_spec.rb`, "does not let an operation row correction explain the matching intent row change" and "still aborts on a duplicate committed reservation when the added row is listed".

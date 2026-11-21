---
module: Timekeeping ownership-state specs
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - spec/support/timekeeping/owned_entries.rb
  - spec/integration/timekeeping/owned_entries_spec.rb
tags:
  - timekeeping
  - arrange-owned-entries
  - projection
  - test-harness
applies_when:
  - A spec needs an entry column that arrange_owned_entries rows do not accept yet.
---

# Add a new arranged-row column in all three harness lists

## Context

`arrange_owned_entries` writes fixture rows to the store that owns entries, and it also writes the `timesheet_entries` projection. Specs depend on both copies holding the same values. Model and policy specs, for example, act on the projection record.

The harness in `spec/support/timekeeping/owned_entries.rb` names the accepted columns in three separate places.

## Solution

When a row needs a new column, add it to all three:

1. `ROW_KEYS`, the keys a row may carry.
2. `OPTIONAL_COLUMNS`, the columns that pass through to the stored entry.
3. The `entry.slice(...)` list in `create_timesheet_entries`, which builds the projection record.

The slice is an allowlist. A column left out of it is dropped from the projection with no error, while the owner copy still has it. Copy the pattern of `source_metadata`, which already sits in all three lists.

Then add an example that reads the value back from both the owner and the projection in each state, plus a row without the key to check its default.

## Why it matters

If the slice is missed, the owner and the projection disagree. In the Timekeeping and rollback states, a model spec then acts on a record without the starting value it arranged, and an audit diff or a normalization check pins the wrong thing.

## Evidence

PR #569 adds `proof_metadata` to `ROW_KEYS`, to `OPTIONAL_COLUMNS` and to the `create_timesheet_entries` slice in `spec/support/timekeeping/owned_entries.rb`.

The same change adds two groups to `spec/integration/timekeeping/owned_entries_spec.rb`. One arranges a row with `proof_metadata` and a row without it in the legacy, rollback and timekeeping states. It checks the owner copy, or the checkpoint rows a stub store receives, and the projection read with `TimesheetEntry.unscoped.find(id).proof_metadata`, expecting `{}` for the plain row. The other repeats the check against the live Timekeeping app.

The audit example `records audits for proof metadata changes` in `spec/models/timesheet_entry_spec.rb` now arranges its starting `proof_metadata` through `arrange_model_entry`.

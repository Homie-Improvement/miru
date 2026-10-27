---
module: Timekeeping::LocalOwner
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/support/timekeeping/local_owner_spec_helpers.rb in PR #189 defines TIMEKEEPING_WRITE_TABLES as the four written tables and timekeeping_row_counts defaults to it; spec/contracts/timekeeping/local_owner_spec_helpers_spec.rb pins that list with contain_exactly; the deleted tenancy example counted only three of them."
audience: both
related_components:
  - spec/support
tags:
  - spec-consolidation
  - row-counts
  - refusal-tests
  - local-owner
applies_when:
  - Replacing per-file row_counts or count helpers with one shared spec helper
  - Reviewing a merged refusal example that compares table counts before and after a call
---

# Default a shared row-count helper to the union of every copy's tables

## Context

Many refusal tests prove that a refused write "changed nothing". They count rows in some tables before the call and compare the counts after it. The check only covers the tables in its list. A stray row in any table left off the list passes unseen.

When the same helper has been pasted into many spec files, the copies drift. Some count all the written tables. Some count only a subset, or count one table through a model instead of SQL. Each copy looks complete when you read it alone.

## Solution

When you fold the copies into one shared helper:

- Collect every table list the copies use, and make the helper's default the union of them. Put it in one named constant, so every spec refers to that constant and none restates the list.
- Count rows by SQL, not through models. A model's default scope can hide a row that a leak check must see.
- Write a spec for the helper that pins the exact list with `contain_exactly`. It should also prove the helper sees a write in each table. Without that, someone can drop a table from the default later and every refusal test still passes.
- Rule for review: a merged example never checks fewer tables than the widest copy it replaces. If an example passes a narrower list on purpose, the reason belongs in a comment.

## Why it matters

A merge that keeps the most common list, or the list from the first file read, loses coverage with no failing test. The copies that watched an extra table were the only guard on that table. The consolidation is meant to keep every assertion, but this loss shows up in no diff of assertions, only in a helper's argument.

## Evidence

PR #189 merges eight `Timekeeping::LocalOwner` spec files into four. It adds `spec/support/timekeeping/local_owner_spec_helpers.rb`, which defines `TIMEKEEPING_WRITE_TABLES = %w[entries entry_audits idempotency_records entry_outbox_items].freeze`. The comment above it says a shorter list would let a leak into the missing table pass. `timekeeping_row_counts(tables = TIMEKEEPING_WRITE_TABLES)` counts each table with `SELECT COUNT(*)`, and its comment says this is so a row outside a model's default scope is still counted.

The old copies had drifted. The deleted version of the foreign-id example in `spec/services/timekeeping/local_owner_tenancy_spec.rb` compared counts for only `entry_audits entry_outbox_items idempotency_records`. Several deleted examples in `spec/services/timekeeping/local_owner_3_spec.rb` counted the outbox through `Timekeeping::LocalOutboxEntry.count` and counted the other tables by SQL. The merged examples call `timekeeping_row_counts` with the full default.

`spec/contracts/timekeeping/local_owner_spec_helpers_spec.rb` pins the list: it expects `TIMEKEEPING_WRITE_TABLES` and the default count keys to `contain_exactly` the four tables. It also checks that one create raises each of the four counts to 1.

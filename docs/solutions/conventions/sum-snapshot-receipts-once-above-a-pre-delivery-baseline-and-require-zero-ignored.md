---
module: timekeeping handoff live specs
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping_projection
tags:
  - exactly-once
  - entry-snapshot-receipt
  - relay
  - multi-company
applies_when:
  - A spec proves queued entry snapshots were applied exactly once by reading EntrySnapshotReceipt rows
  - The queued snapshots span more than one company
---

# Sum snapshot receipts once above a pre-delivery baseline and require zero ignored

## Context

Final projection rows cannot show whether a snapshot was applied twice or skipped and then covered by a later version. So the live interrupted-handoff specs prove exactly-once delivery from `EntrySnapshotReceipt` rows. Each receipt's `response_body` holds `"applied"` and `"ignored"` counts for one delivered batch.

Three details make this sum easy to get wrong:

1. One receipt covers every company in its batch. A per-company sum counts a two-company receipt twice.
2. The baseline (the highest receipt id) has to be taken after the relay is paused and before the run that delivers. If you take it later, you miss receipts. If you take it before the pause, receipts from the baseline catch-up get counted.
3. Checking only `applied` lets a run that ignored one snapshot and applied an extra one elsewhere reach the same total.

## Solution

Use `TimekeepingLiveHandoff.applied_since(receipts, baseline_id:)`. It keeps receipts with `id > baseline_id`, counts each one once, and returns `{ applied:, ignored: }`. Then assert both values together:

```ruby
expect(TimekeepingLiveHandoff.applied_since(receipts, baseline_id: receipt_baseline))
  .to eq(applied: queued.size, ignored: 0)
```

Here `queued` is the combined queued positions of both companies. In the during_checkpoint example, take the baseline before `live_handoff_resume_relay`, because the relay starts delivering as soon as it resumes. Compare final projection rows with the outgoing Timekeeping store, company by company, as a separate check. The receipt sum cannot show a wrong row.

## Why it matters

Each mistake above passes quietly. A doubled count can mask a missing snapshot. A late baseline turns a real double apply into "zero applied". An `applied`-only check hides an ignored snapshot. The meta examples pin each case so the reader fails when the rule breaks.

## Evidence

- PR #595 adds `applied_since` to `spec/support/timekeeping/live_handoff_helpers.rb`. Its comment says one receipt covers every company in its batch, so summing per company would count it twice.
- `spec/meta/timekeeping_live_handoff_helpers_spec.rb` pins the rule. With baseline 4, receipts 5 and 6 are summed and receipt 4 is not. A receipt with `company_ids: [1, 2]` counts once. A nonzero `"ignored"` is reported. Receipts all at or below the baseline sum to zero.
- `spec/integration/timekeeping/interrupted_handoff_spec.rb` asserts `eq(applied: queued.size, ignored: 0)` in the before_freeze resume and the during_checkpoint resume. The during_checkpoint example takes `receipt_baseline` before `live_handoff_resume_relay`.
- Review findings on this pull request said an inline sum skipped the `ignored` check, and that the checkpoint resume had no receipt baseline. The author moved both resumed examples to `applied_since` with zero ignored, and added the baseline.

---
module: Timekeeping proof harness
date: 2026-11-19
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingQueueLedger
tags:
  - queue-ledger
  - merge-rule
  - control-jobs
  - false-negative
applies_when:
  - Merging repeated status observations of the same item into a stored ledger
  - Changing TimekeepingQueueLedger.merge_controls or the control status values
---

# Never let a later clean check overwrite a recorded control failure

## Context

The queue ledger plants two control jobs, one on `default` and one on `billing_sync`, each time a runtime starts. It checks each control more than once. `stop!` checks it, then the next reset checks it again, so a control deleted between those two points is still caught. Each check writes a `Control` with status `unrun`, `ran` or `missing`, keyed by `active_job_id`.

The first merge rule was "the latest check replaces the earlier one". That rule breaks in one sequence. A check records `missing`, then the row is put back before the reset, so the reset check writes `unrun` over it. No execution record exists for that control, so the verdict passed even though the run had already recorded a violation.

## Solution

A failure status is final. A later check replaces an earlier one only while the earlier status is `nil` (never checked) or `unrun`:

```ruby
by_id[control.active_job_id] = control unless earlier&.status && earlier.status != UNRUN
```

Use this rule for any status that the ledger records more than once. Moving from clean to failed is allowed. Moving from failed back to clean is not.

## Why it matters

The ledger exists to prove that a stray worker never ran or removed a job. That proof is only as strong as its weakest merge. If a later clean read can erase an earlier failure, a violation can be hidden by putting the row back, and the suite reports a pass.

## Evidence

- PR #393, `spec/support/timekeeping/queue_ledger.rb`: `merge_controls` keeps an earlier `ran` or `missing` status. Its comment says a control put back after it went missing must still fail the run.
- PR #393, `spec/meta/timekeeping_queue_ledger_spec.rb`: the example "a control recorded missing stays missing when a later check finds it unrun" writes `missing` and then `unrun` for the same control. It expects the stored status `missing` and a failing verdict.
- A code review of this pull request reported the overwrite. The author's recorded run of the spec file returned 0 failures with the new example included.

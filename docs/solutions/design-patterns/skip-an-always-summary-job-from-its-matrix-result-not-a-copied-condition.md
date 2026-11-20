---
module: ci
date: 2026-11-20
problem_type: design_pattern
component: development_workflow
severity: medium
audience: both
related_components:
  - testing_framework
tags:
  - github-actions
  - always
  - matrix-summary
  - needs-result
applies_when:
  - A summary job uses always() and needs a matrix job to report its overall result
  - The matrix job's if condition changes or gains a new reason to skip
---

# Skip an always() summary job from its matrix result, not a copied condition

## Context

In `.github/workflows/validations.yml`, `timekeeping-handoff-result` is a summary check over the `timekeeping-handoff` matrix. It runs under `always()` so it still reports when a matrix leg fails or is cancelled; without `always()`, a failed dependency skips it and the failure would not show in the summary.

It used to carry its own copy of the matrix's skip ci condition. When the matrix gained a new reason to skip (feature-branch pushes), a copied condition would let the summary run anyway. It would then compare a `skipped` result against `success` and fail on every feature-branch push.

## Solution

Take the summary's skip from the matrix itself:

```yaml
needs: timekeeping-handoff
if: always() && needs.timekeeping-handoff.result != 'skipped'
```

- It skips exactly when the matrix skipped, whatever the reason.
- It still runs, and fails, when a leg fails or is cancelled.
- It never repeats the branch list, so the list stays in one place.

Keep `always()`: `needs.timekeeping-handoff.result != 'skipped'` alone would skip the summary when a leg fails.

## Why it matters

A summary that copies the matrix condition must be edited every time the matrix condition changes, and the drift is easy to miss because the matrix itself still behaves. The result is a red required check on branches where nothing ran. Reading the matrix result removes the copy, so later edits to the matrix condition need no edit here.

## Evidence

- PR #490 changes `timekeeping-handoff-result` in `.github/workflows/validations.yml` from `always() && (github.event_name != 'push' || !contains(github.event.head_commit.message, 'skip ci'))` to `always() && needs.timekeeping-handoff.result != 'skipped'`, with a comment saying it skips exactly when the matrix was skipped.
- `spec/meta/ci_spec_coverage_spec.rb` adds the example `fails when the handoff summary goes back to the skip ci condition or drops always()`, which sets both the old condition and the condition without `always()` and expects each to be reported.

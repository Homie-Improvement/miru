---
module: timekeeping handoff
date: 2026-10-27
problem_type: design_pattern
component: handoff_runner
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #197, lib/timekeeping/handoff/runner.rb settle writes money_before only when 'settle_integration.settled? && !report.money_before?' (it returns without writing otherwise), DEFAULT_REPORT_ROOT is Rails.root.join('storage', 'timekeeping_handoff'), and lib/timekeeping/handoff/report_directory.rb keys files by generation-<n>."
audience: both
related_components:
  - report_directory
  - money_snapshot_file
tags:
  - resume
  - baseline
  - money-snapshot
  - idempotency
applies_when:
  - A resumable step saves a comparison baseline before its progress is recorded
  - A later step compares current data against that baseline
---

# Write a resume baseline once per generation, on storage that survives a restart

## Context

The handoff takes a money snapshot of every company at the end of settle (step 2). Reconcile (step 6) compares a second snapshot against it, so a changed invoice value fails the handoff.

Settle writes `money_before.json` before the interpreter records `settle`. If that record fails, a fresh run repeats settle. The first version rewrote the file each time. A money change during the interruption then became the new baseline, and reconcile passed.

A second issue: the default report root was `log/`, which is not a mounted volume in the deployment. A resume in a fresh container found no files and could only abort.

## Solution

- Settle writes the baseline only when `report.money_before?` is false. A repeat keeps the first file.
- A file that exists but cannot be read raises `ReportDirectory::Unreadable`; the run never retakes the snapshot in its place.
- Each generation has its own directory, `generation-<n>`, so a retry after an abort never reads the aborted attempt's baseline.
- The default root is `storage/timekeeping_handoff`, and the `handoff_resume` task description says it needs those files.
- The same rule covers the checkpoint capture time: no `checkpoint.json` means the step has not started and may take a fresh time; a present file must be reused.

## Why it matters

A repeated step looks idempotent if it writes the same kind of file. It is not idempotent if the file's content depends on when it runs. For any baseline a later check compares against, "write if absent, refuse if unreadable" is the safe rule. The storage location must also outlive the process that wrote it, or resume is impossible in practice.

## Evidence

- PR #197, `lib/timekeeping/handoff/runner.rb`: `settle` returns before writing when `report.money_before?` is true; `DEFAULT_REPORT_ROOT` and its comment on the persistent `storage/` directory.
- PR #197, `lib/timekeeping/handoff/report_directory.rb`: per-generation `path`, `money_before?`, `checkpoint?`, `Unreadable`, and write-to-temp-then-rename.
- PR #197, `lib/tasks/timekeeping.rake`: the `handoff_resume` description names the `storage/timekeeping_handoff` files.
- PR #197, `spec/lib/timekeeping/handoff/report_directory_spec.rb`: a later generation never reads an earlier generation's files, and a truncated file refuses.

---
module: timekeeping handoff
date: 2026-10-27
problem_type: design_pattern
component: handoff_runner
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #197, lib/timekeeping/handoff/runner.rb listed_corrections builds from source_copy.values_at(:source, :load), source_copy refuses when digest_text of the load differs from the stored loaded_digest, and reconcile refuses when the exported checkpoint digest differs from the planned load; runner_legacy_handoff_spec.rb tests both drift cases."
audience: both
related_components:
  - reconciliation
  - legacy_load_versions
  - reservation_locks
tags:
  - reconciliation
  - listed-corrections
  - digest
  - resume
applies_when:
  - A copy step deliberately changes some values, and reconciliation must accept those changes
  - A restart can skip the copy step's completion check
---

# Derive expected differences from the planned copy, not from the target

## Context

The handoff loads a modified copy into the incoming owner. On a legacy source, `LegacyLoadVersions` raises versions and sets corrected `locked` values. On a non-legacy source, `ReservationLocks` sets `locked` from reservations. Reconciliation must accept those deliberate changes as listed corrections.

An early version listed every version that differed between the source and the target's actual rows. A target holding version 6 for a source version 7 was therefore "expected". After `checkpoint` is recorded, a restart skips `checkpoint_loaded?`, so nothing else caught it. The value under check approved its own difference.

## Solution

- Build the listed corrections from the planned load copy (`source_copy[:load]`). That copy only raises versions, so a lowered target value is an unlisted difference and reconcile aborts.
- Save both the source digest and the planned copy's digest in `checkpoint.json`. On restart, `source_copy` rebuilds both and refuses if either differs.
- In reconcile, refuse before running checks if the incoming owner's exported digest no longer equals the planned copy's digest.

## Why it matters

A reconciliation is only as strong as its list of allowed differences. If that list is computed from the thing being verified, any drift becomes allowed. Compute it from an independent plan, save a digest of that plan, and recheck the target against the digest at every point a skipped completion check could let drift through.

## Evidence

- PR #197, `lib/timekeeping/handoff/runner.rb`: the `listed_corrections` comment ("so a wrong load can never list its own difference as expected"), the two digest checks in `source_copy`, and the digest check at the start of `reconcile`.
- PR #197, `lib/timekeeping/handoff/legacy_load_versions.rb` and `lib/timekeeping/handoff/reservation_locks.rb`: `listed_corrections(source:, loaded:)` compares the source with the planned copy.
- PR #197, `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb`: a restart after the recorded checkpoint is refused when an uncorrected entry drifts to version 99 or a corrected entry drops to 0; ownership stays with the monolith. The author reported 2 examples, 0 failures.

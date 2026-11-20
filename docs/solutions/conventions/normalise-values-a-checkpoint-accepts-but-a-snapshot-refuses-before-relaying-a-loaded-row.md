---
module: timekeeping handoff
date: 2026-11-20
problem_type: convention
component: timekeeping_handoff
severity: medium
audience: both
related_components:
  - correction snapshots
  - reconciliation
tags:
  - handoff
  - snapshots
  - null-lock
  - value-rules
applies_when:
  - Building a snapshot or other payload by reusing a loaded checkpoint row
---

# Normalise values a checkpoint accepts but a snapshot refuses before relaying a loaded row

## Context

The value rules for a checkpoint entry and for a snapshot are not the same. A legacy timesheet entry may hold `locked: nil`, and a checkpoint accepts that. A snapshot accepts only `true` or `false`. In PR #460, the first cutover sends each raised entry's loaded row, minus `version`, as a snapshot. A nil lock would make the snapshot writer refuse. That would leave the cutover fenced, and every resume would repeat the failure.

## Solution

Fix the value where the row is built, not where it is written.

- `LegacyLoadVersions.build` loads each raised, uncorrected entry with `"locked" => row["locked"] == true`. An uncorrected entry has no reservation, so it is locked exactly when its legacy value is `true`.
- Timekeeping's stored row, its snapshot and the projection after delivery then hold the same value.
- `listed_corrections` lists every field in `LOAD_CHANGED_FIELDS` (`version`, `locked`) whose loaded value differs from the source. Each listing goes under the entry's company, for both the entries and projection checks. So a nil-to-false change shows up as an expected difference at cutover, not as an unexplained one.
- An entry the load does not raise is returned unchanged, so it gets no snapshot and keeps its legacy row.

## Why it matters

"The loaded row minus one field is a valid snapshot" is true only if the two contracts accept the same values for every remaining field. When a new code path sends a row from one contract into another, compare their value rules field by field. Every value the load changes must also be listed for reconciliation, or the cutover aborts on its own fix.

## Evidence

- PR #460, `lib/timekeeping/handoff/legacy_load_versions.rb`: the module comment on nil locks, the lock change in `build`, `LOAD_CHANGED_FIELDS`, and the per-field listing in `listed_corrections`.
- PR #460, `spec/lib/timekeeping/handoff/legacy_load_versions_spec.rb`:
  - Example "raised_snapshots gives a null-lock version-0 legacy entry one snapshot with its own timestamps, a false lock and no version".
  - Example "the cutover lists a locked change only for an entry whose nil legacy lock was loaded as false, under that entry's company".

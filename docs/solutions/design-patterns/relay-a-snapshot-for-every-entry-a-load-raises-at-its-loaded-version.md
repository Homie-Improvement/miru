---
module: timekeeping handoff
date: 2026-11-20
problem_type: design_pattern
component: timekeeping_handoff
severity: high
audience: both
related_components:
  - reconciliation
  - projection
  - outbox relay
tags:
  - handoff
  - snapshots
  - versions
  - rollback
  - projection
applies_when:
  - A handoff load changes a field value that the other owner's read copy also holds
  - Adding a new reason for the first cutover to change a loaded entry row
---

# Relay a snapshot for every entry a load raises, at the version it loaded

## Context

The first legacy cutover loads every timesheet entry into Timekeeping. Timekeeping accepts only a positive version, so `LegacyLoadVersions.build` raises each legacy row from version 0 to at least version 1. The monolith keeps its own read copy of these entries in `timesheet_entries`. That copy, called the projection, changes only when the relay delivers a snapshot from Timekeeping's outbox.

Before PR #460, only corrected entries got a snapshot (entries whose lock state changed). Every raised-only entry stayed at version 0 in the projection. On rollback, reconciliation compares `version` field by field, so it reported each raised entry as an unlisted difference and refused the handoff.

## Solution

Any field the load changes must reach the projection through a snapshot. Do not paper over it with a rollback listing.

- `LegacyLoadVersions.raised_snapshots(source:, loaded:, corrections:)` returns the loaded row, without `version`, for each entry whose loaded version differs from its source version. Corrected entries are left out, because Timekeeping refuses a snapshot list that names one entry twice.
- `Runner#snapshots_by_version` groups the snapshots by the version each entry was loaded at. It calls `write_correction_snapshots` once per group. Usually there is only one group, at `CORRECTION_VERSION` (1). An entry that Timekeeping already stores at a higher version, such as 3, is loaded at 3, so its snapshot must also be written at 3. A snapshot written at 1 would leave the projection behind Timekeeping again.
- At cutover, reconciliation still lists the raised version for both the entries check and the projection check. The projection catches up only after the flip.

The rejected option was to list the 0-against-1 difference as expected on rollback. That would leave the monolith behind Timekeeping for good, and it would hide a real lost write that looks the same.

## Why it matters

Rollback reconciliation never repairs data. Any unlisted difference aborts the handoff. So any change the load makes, now or later, needs a delivery path to the projection. If it has none, the next rollback refuses. A spec that drains through a relay double can pass while the live run fails, so the undelivered-drain example is the guard to keep.

## Evidence

- PR #460, `lib/timekeeping/handoff/legacy_load_versions.rb`: the new `raised_snapshots` function, and the module comment that the relay delivers only outbox rows.
- PR #460, `lib/timekeeping/handoff/runner.rb`: `snapshots_by_version` replaces `correction_snapshots`, and `checkpoint` writes one `write_correction_snapshots` call per version.
- PR #460, `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb`:
  - Example "a rollback whose drain never delivers the raised entries' snapshots is refused at reconcile": it asserts a `projection` / `version` / `changed` unlisted difference for an uncorrected raised entry.
  - Example "a first cutover writes a raised entry's snapshot at the higher version Timekeeping already stores, once": it asserts the snapshot version is 3.
- PR #460, `docs/architecture/timekeeping-soa.md`: sections on versions and on corrected entries reaching the projection.
- Check to run (not evidence from this change): read the drain in the shared runner spec fakes to confirm whether it copies stored entries into the projection.

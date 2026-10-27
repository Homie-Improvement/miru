---
module: imports
date: 2026-10-27
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #208 adds data_imports.attempted_rows, record_attempted_row before gateway.import, forget_attempted_row only when newly_recorded on CERTAIN_REFUSALS, and skip_stored_duplicates, each covered by a named example in spec/services/imports/harvest_time_entries_importer_spec.rb"
audience: both
related_components:
  - data_import
  - timekeeping_gateway
tags:
  - imports
  - rerun
  - duplicate-detection
  - provenance
  - crash-recovery
applies_when:
  - A rerun of a failed batch must skip the rows it already wrote but write identical rows it never wrote
  - Duplicate detection matches stored entries that any import could have written
---

# Journal row attempts before the write, and undo only your own record on a certain refusal

## Context

The Harvest importer skips CSV rows that match an entry already stored with source "import". On a fresh import, one stored match skips every matching row. That rule breaks on a rerun once rows commit one at a time. If a file has two identical lines and only the first was written, the rerun sees one match and would skip both.

So a rerun must tell its own stored entries apart from other imports' entries. Several simple ways to do this are wrong:

- **Creation time.** An entry stored after this data import was created is not proof that this import wrote it. Two uploads queued before either runs break it.
- **Recording after the write.** A crash, or a lost answer from Timekeeping, between the write and the record leaves a written row unrecorded.
- **Clearing the record on any refusal.** A refusal of this call does not prove an earlier run wrote nothing for that line.

## Solution

Keep a durable journal of attempted lines on the data import (`data_imports.attempted_rows`, an integer array kept across runs):

1. **Record before the write.** `record_attempted_row` appends the line with one conditional `update_all`. It returns whether this call added the line or found it already recorded.
2. **Keep the record on uncertain failures.** A timeout, an unreadable answer or a reused-key rejection may mean Timekeeping stored the entry, so the line stays.
3. **Remove it only on a certain refusal, and only if this call added it.** `CERTAIN_REFUSALS` lists errors raised when the row was certainly not written: `ActiveRecord::RecordInvalid`, `OwnershipMoving`, `StaleGeneration`, `EntryWriteClient::Forbidden`. On those, `forget_attempted_row` runs only when `newly_recorded` is true.
4. **Match by the journal.** In `skip_stored_duplicates`, an attempted line takes one stored match and is skipped only while matches remain. Every other row is then skipped if any stored match is still left after the attempted lines have taken theirs, so when an attempted line uses up the only match, an identical row that was not attempted is written. A recorded line whose write never happened finds no match, so the rerun writes it.

## Why it matters

Each wrong option passes the obvious tests. It fails only in one ordering of crash, queue, refusal and the delayed arrival of the local copy. The failure is silent: the import completes, and either an identical row is never written or another import's row is stored twice. When you change this code, keep all four rules together; dropping any one reopens a case covered below.

## Evidence

PR #208:

- `db/migrate/20261027164215_add_attempted_rows_to_data_imports.rb` adds `attempted_rows` with `default: []` and `null: false`.
- `app/services/imports/harvest_time_entries_importer.rb` adds `CERTAIN_REFUSALS`, `create_entry` (record, write, conditional forget), `record_attempted_row`, `forget_attempted_row` and `skip_stored_duplicates`.
- `spec/services/imports/harvest_time_entries_importer_spec.rb` covers each ordering by name:
  - "skips every matching row of an upload queued before an earlier upload stored its entry" (why timestamps fail),
  - "writes the second identical row on a rerun when the run stopped right after the first row was written" (why recording happens first),
  - "skips both identical rows on a rerun when the first was refused and another import then stored a match" (why a certain refusal removes the line),
  - "keeps an earlier write's record through a refused retry, so the identical row is written once the local copy arrives" (why only this call's own record is removed),
  - "skips every identical row of a fresh import when one matching entry is already stored" (fresh imports keep the old rule).
- In PR #208 review, the author reported these examples passing (48 examples, 0 failures) after the final fix.

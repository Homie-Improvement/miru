---
module: timekeeping
date: 2026-11-20
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - database
tags:
  - postgresql
  - sequences
  - setval
  - seed-capture
  - rollback
applies_when:
  - A restore or copy sets sequence values with setval inside a transaction
  - A failed restore falls back to a real load that must produce the same ids
---

# Reset sequences again after a failed restore, because setval is not rolled back

## Context

`Timekeeping::SeedCapture#restore!` copies saved rows back into empty tables and sets every sequence to its saved value. It runs inside one transaction, so a failure rolls the rows back. But PostgreSQL never rolls back `setval`. After a failed restore the tables are empty, yet the sequences may already point past the seeded ids.

`Timekeeping::SeedDispositionRecorder.load_fresh_seed!` falls back to running `db/seeds.rb` when a restore fails. The seed's ids depend on starting from reset sequences. Without a second reset, the fallback load writes the same rows under shifted ids, and nothing in an empty-table check shows it.

## Solution

- Set sequences last in the restore, after every row copy, so most failures happen before any sequence moves.
- Run cheap checks that can fail (here, that every attachment file still exists) before any write.
- In the caller, treat a restore failure as one named error (`SeedCapture::RestoreError`). On that error, reset every sequence again, then run the real load:

```ruby
def restore_capture(capture, tables)
  return false unless capture

  capture.restore!(connection:)
  true
rescue SeedCapture::RestoreError => e
  Rails.logger.warn("Seed capture restore failed, loading db/seeds.rb instead: #{e.message}")
  reset_sequences(tables)
  false
end
```

The reset that runs before the restore cannot repair this. It runs too early. The repair must sit after the failure.

## Why it matters

Specs that use the two-tenant seed rely on the same ids on every load. A fallback that silently shifts ids makes those specs fail far from the cause, or pass against data that is not the seed. Any future code that restores sequences inside a transaction has the same gap.

## Evidence

- PR #426 adds `restore_capture` and `reset_sequences` in `lib/timekeeping/seed_disposition_recorder.rb`; the rescue branch calls `reset_sequences(tables)` before returning false.
- `lib/timekeeping/seed_capture.rb` checks blob files before the transaction and calls `set_sequence` after all `copy_in` calls; its comment on `restore!` states that PostgreSQL never rolls back setval.
- `spec/lib/timekeeping/seed_disposition_recorder_spec.rb` has the example "after a restore that moved sequences and then failed, falls back to a real load with the same ids and sequence values and replaces the capture". Its stand-in capture calls `setval(..., 900000)` on the users and timesheet_entries sequences, then raises `RestoreError`; the example expects the original ids and sequence states after the fallback.

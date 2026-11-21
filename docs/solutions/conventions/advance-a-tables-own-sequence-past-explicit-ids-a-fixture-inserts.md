---
module: timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - database
tags:
  - postgres-sequence
  - explicit-id
  - fixtures
  - rollback-state
applies_when:
  - A spec helper inserts rows with explicit ids into a table that has its own serial sequence
  - Ids come from a different table's sequence so two tables share one id
---

# Advance a table's own sequence past the explicit ids a fixture inserts

## Context

The rollback fixture writer in `spec/support/timekeeping/owned_entries.rb` gives each entry that names no id one drawn from the `timesheet_entries` sequence (a row with an explicit `id:` keeps it). It does this so the owner row in `entries` and its projection row in `timesheet_entries` share one id. Then it inserts that id into `entries` explicitly.

In Postgres, an insert that names its id does not move the table's sequence. The `entries` sequence stays behind. The local owner draws new entry ids from that sequence, so a later create in the same example can get an id a fixture row already holds. Committed-data cleanup does not reset sequences, so whether it collides depends on which specs ran before.

The same gap exists inside one sequence. A row given an explicit `id:` does not consume that value from `timesheet_entries`, so a later drawn id can equal it.

## Solution

After the explicit-id inserts, move the table's own sequence past the highest id, and never move it back:

```ruby
sequence = connection.select_value("SELECT pg_get_serial_sequence('entries', 'id')")
last_value = connection.select_value("SELECT last_value FROM #{sequence}").to_i
connection.select_value(
  ApplicationRecord.sanitize_sql_array(["SELECT setval(?, ?, true)", sequence, [last_value, above].max])
)
```

Taking the maximum keeps the sequence monotonic. Another spec may already have pushed it higher, and lowering it would cause the collision this step exists to stop.

When the helper draws ids itself, skip any drawn value that equals an explicit id in this batch or one arranged earlier in the example (`with_drawn_ids`). Otherwise the owner write succeeds and the projection write fails on a duplicate key.

## Why it matters

A comment such as "an id no later local row can take" is only true for the sequence the id came from. Any other table that receives the same id needs its own sequence moved. Without that, the failure appears in a later spec, far from the fixture that caused it.

## Evidence

- PR #473 adds `advance_prepared_entry_ids(above:)` to `spec/support/timekeeping/owned_entries.rb` and calls it at the end of `create_prepared_entries`.
- The same file's `with_drawn_ids` skips drawn values already taken by explicit ids.
- `spec/integration/timekeeping/owned_entries_spec.rb` adds "rollback state: a prepared entry created after arranging gets an id above every arranged id" and "legacy state: a row without id skips a sequence value already arranged as an explicit id".
- A build review on PR #473 found the gap. The author reported that the new rollback example fails with the sequence advance removed and passes with it.

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
  - postgresql
  - sequences
  - pg-sequences
  - is-called
  - seed-capture
applies_when:
  - Saving and restoring PostgreSQL sequence state
  - Comparing sequence state before and after a load or restore in specs
---

# Read sequence state from each sequence, not from pg_sequences

## Context

A sequence's next value depends on two fields: `last_value` and `is_called`. A sequence that never supplied a value has `is_called = false`, and its next value is `last_value` itself. The `pg_sequences` view has no `is_called` column, and it shows `last_value` as NULL for such an unused sequence.

In this repository the timekeeping ownership row is written with a fixed id, so its sequence can stay unused after a seed load. A capture built from `pg_sequences` cannot restore that sequence's next id.

## Solution

List sequences from the catalog, then read each one directly:

```ruby
names = connection.select_values(<<~SQL.squish)
  SELECT c.relname FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'S' AND n.nspname = current_schema()
  ORDER BY c.relname
SQL
names.map do |name|
  connection.select_one("SELECT last_value, is_called FROM #{connection.quote_table_name(name)}")
end
```

Restore with the three-argument form, `setval(name, last_value, is_called)`, so used and unused sequences both come back exactly. In specs, compare `[last_value, is_called]` and also the next generated id, which catches a wrong `is_called`.

## Why it matters

A restore that drops `is_called` gives the next row an id one higher than a real load would. Specs that expect "the same ids and sequence values" then drift, and the drift only shows for sequences that were never used.

## Evidence

- PR #426 adds `read_sequences` and `set_sequence` in `lib/timekeeping/seed_capture.rb`, with a header comment that pg_sequences has no is_called column and shows NULL for an unused sequence.
- `spec/support/seed_state_comparison.rb` `sequence_states` reads `last_value, is_called` from each sequence the same way.
- `spec/lib/timekeeping/seed_capture_spec.rb` compares sequence states and the next ids of the `users` and `timekeeping_ownership` sequences before and after a restore.

---
module: timekeeping/handoff
date: 2026-10-27
problem_type: convention
component: timekeeping_handoff
severity: medium
evidence_grounding: anchored
grounding_evidence: lib/timekeeping/handoff/source_intents_file.rb maps each column of Reconciliation::INTENT_COLUMNS to one type and reads times back as Time; spec/lib/timekeeping/handoff/report_directory_spec.rb asserts the reread rows eq the written rows and that created_at is a Time.
audience: both
related_components:
  - report_directory
  - reconciliation
tags:
  - codec
  - json
  - resume
  - baseline-file
applies_when:
  - Rows read from the database are saved to a file and read back on resume
  - The read-back rows are compared field by field with == against a fresh database read
---

# Restore database types when a saved baseline is compared with fresh rows

## Context

In PR #244 the handoff runner saves the `invoice_operation_intents` rows to `source_intents.json` at the checkpoint. A resumed run reads them back, and reconcile compares each field with `==` against a fresh database read.

`JSON.generate` followed by `JSON.parse` does not give back the same Ruby values. A `Time` comes back as a string, and a string never equals a `Time`. With plain JSON, a resume with no change at all would report a difference in `created_at` and `finished_at` on every row.

## Solution

Write and read the file through a codec that gives each column exactly one type, and refuse the whole file when a value has another type. `Timekeeping::Handoff::SourceIntentsFile` holds this as a table:

```ruby
COLUMN_TYPES = {
  "id" => :integer, "company_id" => :integer, "invoice_id" => :integer, "operation_id" => :string,
  "generation" => :integer, "desired_entry_ids" => :integer_array, "disposition" => :string,
  "state" => :string, "created_at" => :time, "finished_at" => :optional_time
}.freeze
```

Times are written as UTC `iso8601(6)` and loaded back as `Time`. Six digits keep the microseconds the database stores, so the loaded value equals a fresh read. The codec walks `Reconciliation::INTENT_COLUMNS`, so a column added there without a type fails loudly instead of being dropped.

Test it two ways: a unit round trip that asserts the loaded rows `eq` the written rows and their classes, and a resume with nothing changed that must finish the handoff.

## Why it matters

A lossy baseline fails in one of two bad ways. If it compares unequal, every resume is refused for differences that do not exist. If a loader quietly returns a partial or empty list for bad text, the comparison misses real deletions. Strict types and refusing bad files close both.

## Evidence

- PR #244 adds `lib/timekeeping/handoff/source_intents_file.rb`. Its comment says reconciliation compares each field with `==`, "so every column is read back as the type a database read gives: plain JSON would leave a time as a string".
- `spec/lib/timekeeping/handoff/report_directory_spec.rb` writes rows with microsecond times, a nil `finished_at` and an integer array, and expects the reread rows to `eq` them, with `created_at` a `Time` and `id` an `Integer`.
- `spec/lib/timekeeping/handoff/source_intents_file_spec.rb` expects `SourceIntentsFile::Unreadable` for quoted integers in `desired_entry_ids`, truncated text, `""`, `"null"`, a non-array `rows`, and a renamed column.
- `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb` adds a resume with unchanged intents that finishes the cutover with owner `timekeeping`.

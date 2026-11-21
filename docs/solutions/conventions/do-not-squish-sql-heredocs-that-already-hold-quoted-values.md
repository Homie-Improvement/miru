---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: projection_consumer
severity: high
audience: both
related_components:
  - timesheet_entries
  - relay
tags:
  - sql
  - squish
  - quoting
  - heredoc
  - data-integrity
applies_when:
  - Building SQL text by interpolating `connection.quote` values into a heredoc
  - Reviewing a `<<~SQL.squish` heredoc that contains user-entered values
---

# Do not squish a SQL heredoc that already holds quoted values

## Context

`String#squish` removes leading and trailing whitespace and turns every run of whitespace into one space. It does not know about SQL. If quoted values are already in the string, squish changes them too.

`Timekeeping::ProjectionConsumer#upsert_sql` built its `INSERT ... ON CONFLICT` statement by putting `connection.quote(value)` literals into a `<<~SQL.squish` heredoc. Each note the relay delivered to `timesheet_entries` lost its line breaks and repeated spaces. For example, `"Programming - Built landing\nand tests"` was stored with the line break turned into a space. Nothing raised an error. The changed note also broke duplicate detection: the importer matches existing rows by note, so a reimport of that row was no longer recognized as a duplicate.

## Solution

If a heredoc already contains quoted values, do not squish it. Leave the whitespace in the SQL. PostgreSQL ignores whitespace between tokens, so the only effect of squish was the damage it did inside the literals. The fix removes `.squish` and adds a comment that explains why:

```ruby
# Not squished: the values are already quoted into the text, and
# squish would collapse line breaks and spaces inside them.
<<~SQL
  INSERT INTO timesheet_entries (...) VALUES (...)
  ON CONFLICT (id) DO UPDATE SET ...
  WHERE timesheet_entries.version < EXCLUDED.version
SQL
```

Squish is still safe where values are bound after the squish, for example with `sanitize_sql_array`. In that case squish runs before any value is in the text. The order is what matters: squish first, then quote.

A test for this must deliver values that squish would change: line breaks, two or more spaces, tabs and carriage returns. It must also include quotes and backslashes, to prove the values are still escaped. Compare bytes, not only strings. Test the UPDATE half of the upsert as well as the INSERT half.

## Why it matters

This is silent data corruption on a live write path. Every relayed note was changed in the same way, and the rows written before the fix stay changed, because the fix does not repair them. Ordinary test notes such as `"note"` have no repeated whitespace, so normal tests never catch it. A reviewer has to check the order: was the text squished before or after the values went in?

## Evidence

- PR #491 removes `.squish` from the `upsert_sql` heredoc in `app/services/timekeeping/projection_consumer.rb` and adds the comment shown above.
- PR #491 adds examples to `spec/services/timekeeping/projection_consumer_spec.rb`. They store notes with line breaks, repeated spaces, tabs, quotes, backslashes, CRLF and SQL-shaped text byte for byte, including on a same-key redelivery and on a version 2 update whose note differs only in whitespace (`"a b"` to `"a  \n  b"`).
- The importer example in `spec/services/imports/harvest_time_entries_importer_spec.rb` checks that the multi-line note `"Programming - Built landing\nand tests"` is stored once, and that a reimport adds no entry. When PR #491 added it, the example was pinned to the rollback state. Since PR #538 it runs in whichever ownership state the run selects, and it counts the owning store's entries through `owned_entries`.

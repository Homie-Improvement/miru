---
module: spec/meta
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - database
tags:
  - postgres
  - to-regclass
  - search-path
  - pg-temp
  - temp-table
  - spec-merge
applies_when:
  - A spec proves that a guard or cleanup left no table behind
  - Duplicate examples that check for a leftover table are being merged
---

# Check a dropped table with the unqualified to_regclass name too

## Context

The writer log specs prove that `TimekeepingWriterLog.guarding` leaves no `miru_writer_log` table behind after a failure. Two older examples checked this in two ways:

- `to_regclass('public.miru_writer_log') IS NULL` looks only in the `public` schema.
- `to_regclass('miru_writer_log')` has no schema, so Postgres resolves the name through `search_path`. That path checks `pg_temp` first.

While the two examples were being merged into one, the merged example first kept only the `public` form. That looked like removing a duplicate. It was a weaker check: `remove!` drops only `public.miru_writer_log`, so a session-local TEMP table with the same name would outlive the guard, and the `public` lookup would still pass.

## Solution

When a spec proves that a table is gone, assert both lookups. Do this at every point where the spec checks for leftovers:

```ruby
expect(connection.select_value("SELECT to_regclass('public.miru_writer_log') IS NULL")).to be(true)
# The unqualified name follows search_path, pg_temp first, so a session-local leftover also fails.
expect(connection.select_value("SELECT to_regclass('miru_writer_log')")).to be_nil
```

When you merge examples, do not treat a schema-qualified lookup and an unqualified lookup as copies of one check. Keep each one unless the surviving example has another assertion that covers the same object.

## Why it matters

This support code installs a table, a function and a trigger that must work across sessions. A TEMP table or a `pg_temp` function would be visible only to the session that installed it, which is the mistake these specs exist to catch. The `public` lookup proves only that the shared table was dropped. Only the unqualified lookup also proves that no table with the same name hides in the session's temporary schema. If you drop it, a regression that creates the log as a TEMP table can pass the guard spec.

## Evidence

- PR #467 changes `spec/meta/timekeeping_writer_log_spec.rb`. In the `.guarding` context, the example `re-raises a failure after a logged write and leaves no trigger, function or table` asserts both `to_regclass('public.miru_writer_log') IS NULL` and `to_regclass('miru_writer_log')` to be nil. It does this after the raise and again after a further `described_class.remove!(connection)`. A comment beside those lines states the search_path reason.
- The removed `TimekeepingWriterLog guarding failure` example in the same diff used only the unqualified lookup. The removed `TimekeepingWriterLog guarding` example used only the `public` lookup.
- A review of PR #467 found that an earlier version of the merged example kept only the `public` lookup. The author then added the unqualified lookup back. As a check, the author temporarily made `guarding` create `TEMP TABLE miru_writer_log` after `remove!` and ran `bundle exec rspec spec/meta/timekeeping_writer_log_spec.rb`. The result was 47 examples with 1 failure, in the `.guarding` example.

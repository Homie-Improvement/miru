---
module: spec/timekeeping
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support
  - solid_queue
tags:
  - database-cleaner
  - truncation
  - only-option
  - queue-ledger
applies_when:
  - Calling DatabaseCleaner.clean_with or TestDatabaseCleanup.clean_with! with an only list computed at runtime
  - Replacing a raw SQL TRUNCATE guarded by an any? check with a DatabaseCleaner call
---

# Refuse an empty `only:` list before a DatabaseCleaner truncation

## Context

The after hook in `spec/timekeeping/runtime_queues_spec.rb` used to run a raw SQL `TRUNCATE` over the monolith's `solid_queue_` tables. It skipped the statement when the list was empty. This change replaced it with `TestDatabaseCleanup.clean_with!(:truncation, only: queue_tables)`.

The comment the change adds explains the problem: DatabaseCleaner reads an empty `only:` list as every table. The plan names database_cleaner-active_record 2.2.2 as the version where this holds. No test in this change shows that behaviour, so check it again after you upgrade the gem.

## Solution

Check a computed `only:` list before the call, and raise if it is empty:

```ruby
queue_tables = ActiveRecord::Base.connection.tables.grep(/\Asolid_queue_/)
raise "the monolith test database has no solid_queue_ tables" if queue_tables.empty?

TestDatabaseCleanup.clean_with!(:truncation, only: queue_tables)
```

Do not change it to `clean_with!(...) if queue_tables.any?`. `clean_with!` also runs the collect step (`before_reset!`). The same hook later truncates the separate Timekeeping database's queue tables. If you skip the call, that later truncate runs with no record taken first.

## Why it matters

With an empty list, a reset meant to clear a few queue tables would empty the whole monolith test database. Skipping the call instead loses queue executions without a trace. Raising states the hook's assumption, that the schema defines the `solid_queue_` tables, and makes a broken setup fail loudly in place of either quiet outcome.

## Evidence

- PR #418 changes `spec/timekeeping/runtime_queues_spec.rb`. It adds the comment that DatabaseCleaner reads an empty `only:` list as every table and that skipping would leave the Timekeeping queue tables cleared with no record. It adds the `raise` and the `clean_with!(:truncation, only: queue_tables)` call before the Timekeeping `TRUNCATE`.
- In the same pull request, `spec/meta/test_database_cleanup_reset_sites_spec.rb` has an example asserting that `clean_with!` passes a bare `only:` list through with no added `except:` default.
- Verification step to run, not evidence: after you upgrade database_cleaner-active_record, confirm that `only: []` still means every table.

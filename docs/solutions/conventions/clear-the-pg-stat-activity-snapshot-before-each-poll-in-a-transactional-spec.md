---
module: spec/lib/timekeeping_demo
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - database
tags:
  - pg-stat-activity
  - postgresql
  - polling
  - database-cleaner
  - flaky-spec
applies_when:
  - A spec polls pg_stat_activity or another pg_stat view in a retry loop
  - The example runs inside a transaction, such as a DatabaseCleaner transaction strategy
---

# Clear the pg_stat_activity snapshot before each poll in a transactional spec

## Context

The live boot spec waits for each app's database connections to appear. It polls `pg_stat_activity` (the PostgreSQL view that lists open server connections) for up to 60 seconds. The example has no committed tag, so it runs inside a DatabaseCleaner transaction.

PostgreSQL takes one snapshot of the statistics views per transaction. Every later read in the same transaction returns that first snapshot. So a retry loop inside the transaction rereads the same answer. If a connection opens after the first read, the loop never sees it and the example fails, even though the code under test works.

## Solution

Run `SELECT pg_stat_clear_snapshot()` before each read of the view:

```ruby
def boot_isolation_users_tagged(probe)
  ActiveRecord::Base.connection.execute("SELECT pg_stat_clear_snapshot()")
  sql = ActiveRecord::Base.sanitize_sql_array(
    ["SELECT DISTINCT usename FROM pg_stat_activity WHERE application_name = ?", probe]
  )
  ActiveRecord::Base.connection.select_values(sql).sort
end
```

Keep a comment that says why the call is there. Without it, the line looks like noise and a later edit may drop it.

## Why it matters

The failure looks like a slow boot or a flaky CI job, not a frozen read. A longer timeout does not help, because every poll returns the same rows. The fix costs one statement per poll and does not need the example to leave its transaction.

## Evidence

- PR #468 adds `boot_isolation_users_tagged` in `spec/lib/timekeeping_demo/boot_database_isolation_live_spec.rb`. It calls `pg_stat_clear_snapshot()` before each `pg_stat_activity` query, with a comment that the example runs inside a transaction.
- The review finding on this pull request reported that the 60 second retry loop reread its first result. The author's check opened a transaction, counted backends with a given application_name, opened such a connection, and counted again. It returned `before: 0, same txn: 0, after clear: 1`.

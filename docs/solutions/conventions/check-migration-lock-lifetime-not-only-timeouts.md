---
module: Timekeeping
date: 2026-10-25
problem_type: convention
component: database
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #44 separates column creation in db/migrate/20261025120000_prepare_monolith_for_timekeeping.rb from the nontransactional migration db/migrate/20261025120100_backfill_timesheet_entry_company_ids.rb; app/services/timekeeping/entry_company_backfill.rb updates bounded ID ranges."
audience: both
related_components:
  - timesheet_entries
  - database_migrations
tags:
  - postgres
  - migrations
  - backfill
  - locking
applies_when:
  - Adding a column and filling existing rows on a table used by requests
  - Assessing whether migration timeouts or batched updates prevent blocked traffic
---

# Check migration lock lifetime, not only timeouts

## Context

Commit column changes before filling existing rows. Batching the updates is not enough when the surrounding transaction retains the schema lock.

Adding a column takes a table lock that blocks ordinary reads and writes until the transaction commits. An update in that same transaction extends the blocked interval across the backfill.

`lock_timeout` limits the wait to acquire a lock. It does not limit how long the migration holds that lock afterward. `statement_timeout` limits statement execution, not the transaction's total lock lifetime. Neither setting replaces a suitable transaction boundary.

## Solution

Use separate transaction boundaries for the schema change and the data update.

In this change, `PrepareMonolithForTimekeeping` adds the columns without invoking the backfill. The following migration runs the backfill separately:

```ruby
class BackfillTimesheetEntryCompanyIds < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    Timekeeping::EntryCompanyBackfill.call(connection)
  end

  def down; end
end
```

`EntryCompanyBackfill` updates ranges of 10,000 identifiers. Its SQL changes only `company_id` and skips values that already match. This makes interrupted work safe to repeat.

Keep the service outside any enclosing transaction when separate batch commits matter. Moving the loop into a service does not change transaction ownership.

Check data correctness and lock lifetime separately. A rollback-and-migrate test inside an example transaction checks preservation, but does not demonstrate separate batch commits.

## Why it matters

A fast column addition can still block entry pages, timers and billing work throughout a slow backfill. The important boundary is the commit that releases the schema lock, not the number of update statements.

Use transaction structure to prevent that prolonged block. Treat timeouts as failure limits, not proof that requests remain available.

## Evidence

PR #44, head `9ee9f2d66a4aeb1560bcdf330cd68ab38e7d536b`:

- `db/migrate/20261025120000_prepare_monolith_for_timekeeping.rb` adds the entry columns without calling the backfill. Its comment explains that the column-addition lock must be released before rows are rewritten.
- `db/migrate/20261025120100_backfill_timesheet_entry_company_ids.rb` declares `disable_ddl_transaction!` and invokes the backfill separately.
- `app/services/timekeeping/entry_company_backfill.rb` defines `BATCH_SIZE = 10_000` and updates successive ID ranges. Its SQL assigns only `company_id` and uses `IS DISTINCT FROM` to skip matching values.
- `spec/db/migrations/prepare_monolith_for_timekeeping_spec.rb` runs migrations inside the example transaction and compares existing entry and billing rows. This checks preservation, not production lock duration.

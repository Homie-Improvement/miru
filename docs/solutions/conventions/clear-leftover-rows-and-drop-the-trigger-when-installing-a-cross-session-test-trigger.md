---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - database
tags:
  - postgres-trigger
  - test-instrumentation
  - idempotency
  - unlogged-table
  - crashed-run
applies_when:
  - A spec installs a trigger and log table that must record writes made by other database sessions
  - An install helper is meant to be safe to run again after a run that died before its cleanup
---

# Clear leftover rows and drop the trigger when installing a cross-session test trigger

## Context

Some specs need to know who wrote a row, including writes made by other database sessions such as a worker thread or the app's own processes. The older writer check in `spec/services/timekeeping/projection_consumer_spec.rb` uses a `CREATE TEMP TABLE` and a `pg_temp` function. Postgres shows TEMP objects only to the session that creates them, so writes from any other session never reach that log.

To see every session, `TimekeepingWriterLog` uses a real `UNLOGGED` table, `public.miru_writer_log`, and a public-schema function. These are ordinary database objects. Unlike TEMP objects, they do not disappear when the session ends. If a run is killed (for example by SIGKILL, a CI timeout or a lost connection) before `remove!` runs, the table and trigger stay behind. The trigger then keeps logging every later write, including cleaner deletes and setup inserts.

## Solution

In `install!`, run these steps in this order:

1. `CREATE UNLOGGED TABLE IF NOT EXISTS public.miru_writer_log ...`
2. `DELETE FROM public.miru_writer_log`. This empties rows a dead run left behind.
3. `CREATE OR REPLACE FUNCTION public.miru_writer_log_record() ...`
4. `DROP TRIGGER IF EXISTS miru_writer_log_trigger ON timesheet_entries`
5. `CREATE TRIGGER miru_writer_log_trigger AFTER INSERT OR UPDATE OR DELETE ...`

Dropping the trigger first means a leftover trigger is replaced, not added a second time. `remove!` drops the trigger, then the function, then the table, each with `IF EXISTS`, so it is safe to run twice. Use `guarding(connection) { ... }`, or call `remove!` in an `ensure`, so that a failing block still removes the trigger.

Test the crashed-run case with a stale row present. Insert a row into the log between two `install!` calls. Then assert that `rows` returns only the new write and that `pg_trigger` holds exactly one `miru_writer_log_trigger`.

Use `DELETE FROM` to empty the table, not TRUNCATE. `spec/meta/test_database_cleanup_reset_sites_spec.rb` refuses a raw TRUNCATE outside its two allowed files.

## Why it matters

`IF NOT EXISTS` makes table creation safe to repeat, but it keeps the old table's rows. An install-twice test that runs against an empty table passes and still hides the bug. In a real run, the next guard's exact-row assertions then see writes it never made. Writes from a dead run also have no `miru.writer` mark, so they show up as false NULL-writer violations. Emptying the table on install is what makes "install twice logs a write once" true after a crash, not only after a clean run.

## Evidence

- PR #450 adds `spec/support/timekeeping/writer_log.rb`. In it, `install!` runs `CREATE_LOG_TABLE_SQL`, `CLEAR_LOG_SQL`, `CREATE_RECORD_FUNCTION_SQL`, `DROP_TRIGGER_SQL` and `CREATE_TRIGGER_SQL` in that order. A code comment says a leftover table keeps the dead run's rows.
- In `spec/meta/timekeeping_writer_log_spec.rb`, the "crashed-run install" example inserts a `stale_run` row between two `install!` calls. It then asserts one trigger in `pg_trigger` and only the new INSERT in `rows`.
- A code review on PR #450 raised the stale-row problem. The author reran that example with the clear step removed from `install!`. It failed, and `rows` also returned the `stale_run` row. With the clear step in place, the run reported 44 examples and 0 failures.
- The same file's "remove twice" example calls `remove!` again in an `ensure`, so a failing first removal does not leave the trigger on for later examples.

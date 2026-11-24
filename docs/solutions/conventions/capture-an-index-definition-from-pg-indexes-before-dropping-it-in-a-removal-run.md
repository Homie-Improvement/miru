---
module: invoices
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: author
related_components:
  - database
tags:
  - removal-run
  - unique-index
  - pg-indexes
  - test-database
  - restore
applies_when:
  - Proving a spec depends on a unique or partial index by dropping that index in the test database
  - An index name exists in both the monolith and the Timekeeping databases
---

# Capture an index definition from pg_indexes before dropping it in a removal run

## Context

A removal run proves that a test depends on a mechanism. You take the mechanism away, watch the test fail, then put it back. For a lock call, putting it back is `git checkout` on the file. A unique index is different. Dropping it changes the test database, not the tree, so `git diff --stat -- app lib db` stays empty while the index is still gone. A partial index also carries a `WHERE` clause and column order that are easy to get wrong when you retype them.

One more trap: `index_invoice_operations_one_prepared_per_invoice` exists in both the monolith test database and the Timekeeping database. Dropping the wrong one proves nothing about a monolith spec.

## Solution

1. Pick the database the code under test writes to. For the prepared-reservation adapter, that is the monolith test database (`miru_web_test`).
2. Query `pg_indexes` for the index and save its `indexdef` text before you drop anything.
3. Run `DROP INDEX <name>` in that database only, then run the example and record the assertion failure.
4. Recreate the index by running the saved `indexdef` text unchanged. `bin/rails db:test:prepare` also works.
5. Query `pg_indexes` again and check that the definition matches the saved text. Rerun the example and confirm it passes.

Never edit the migration or `db/schema.rb` for this.

## Why it matters

A test database left without the index makes later runs pass or fail for the wrong reason, and nothing in the tree shows it. A recreated index whose `WHERE` clause differs, for example one that drops the `state = 'prepared'` condition, refuses valid writes in later specs.

## Evidence

PR #625 records this run under **One-prepared-per-invoice index** in `docs/solutions/conventions/identify-the-lock-a-session-waits-on-not-only-that-it-is-blocked.md`. The index was dropped in `miru_web_test` only. The record says the index of the same name in the Timekeeping database was left alone because the adapter writes only to the monolith. With the index gone, the example in `spec/services/invoices/prepared_reservations_concurrency_spec.rb` failed with `Expected ["prepared", nil] to eq ["retryable", "unresolved_operation"].`. The index was restored with `CREATE UNIQUE INDEX index_invoice_operations_one_prepared_per_invoice ON public.invoice_operations USING btree (company_id, invoice_id) WHERE ((state)::text = 'prepared'::text)`, the definition `pg_indexes` reported before the drop. `pg_indexes` then listed the same definition, and the example passed again.

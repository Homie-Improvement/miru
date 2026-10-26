---
module: spec_support
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - database_cleaner
tags:
  - rspec
  - database-cleaner
  - test-isolation
  - committed-data
  - hook-order
applies_when:
  - Code under test writes rows on a connection other than the example's own
  - Adding cleanup to spec/support/database_cleaner.rb
---

# Clean cross-connection rows in a last-declared hook on its own connection

## Context

Most examples run inside a transaction that `DatabaseCleaner` rolls back. A row written on a different connection, such as one opened from another thread, is committed outside that transaction. The rollback does not remove it, so the row leaks into whatever example runs next in random order.

The invoice operation coordinator will commit intent and outbox rows on its own connection. So `invoice_operation_intents` and `invoice_operation_outbox_items` need cleanup after every example, not only after tagged ones.

## Solution

In `spec/support/database_cleaner.rb`:

- Declare the cleanup hook last, as `config.append_after`. RSpec runs `append_after` hooks in the order they are declared, so a hook declared last runs after `DatabaseCleaner.clean`.
- Run the deletes on a connection built outside the pool: `db_config.adapter_class.new(db_config.configuration_hash)`, cached in `TestDatabaseCleanup.ledger_cleanup_connection`. After hooks run while the example's stubs are still active. Some specs stub `ActiveRecord::Base.connection` or methods on a pooled connection, and a delete through those stubs fails or does nothing.
- For examples tagged `committed_data: true`, which run with no transaction, delete all data both before and after the example. The before step means a tagged example starts from empty tables whatever ran before it. Deletion also empties the ownership table, so `delete_all_committed!` calls `TimekeepingOwnership.ensure_initial!` after it.

These deletes cover every company, so they belong in the test database only.

## Why it matters

A cleanup that uses the normal pooled connection passes on its own. It fails only when it meets a spec that stubs the connection, so the failure points at an unrelated file. A cleanup declared before `DatabaseCleaner.clean` runs while the example's transaction is still open. Hook order is not visible from any single spec, so test the registered hooks directly, not only the helper.

The pooled connection would remove one connection path, but it means editing every spec that stubs it. This pull request chose the separate connection so those specs pass unchanged.

## Evidence

PR #80 changes `spec/support/database_cleaner.rb`. It adds the `TestDatabaseCleanup` module with `delete_all_committed!`, `delete_operation_ledger_rows!` and `ledger_cleanup_connection`. A final `config.append_after` carries the comment "Declared last so it runs after DatabaseCleaner.clean." A new `config.before(:each, committed_data: true)` hook calls `delete_all_committed!`. `spec/db/committed_data_mode_spec.rb` runs an ordinary inner example through the suite's real hooks. That example commits intent and outbox rows from another thread, and the spec checks that a second connection then counts zero of each. In the pull request's code review, a reviewer asked to drop the separate adapter and narrow the stubs in `spec/lib/timekeeping/preflight_spec.rb` and `spec/requests/health_spec.rb`. The author declined, because those files are outside this change. This document names those files as the pull request's discussion does and does not quote them.

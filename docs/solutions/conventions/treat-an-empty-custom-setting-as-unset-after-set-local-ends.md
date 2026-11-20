---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - database
  - Timekeeping::LegacyWriterMark
tags:
  - postgresql
  - current-setting
  - set-local
  - session-marker
  - connection-pool
  - writer-log
applies_when:
  - Code or SQL reads a custom session setting such as miru.writer with current_setting(name, true)
  - A trigger or log decides whether a write was marked by reading a session setting
  - A spec needs to prove how an unmarked write behaves on a reused pooled connection
---

# Treat an empty custom setting as unset after SET LOCAL ends

## Context

The single-writer guard marks each write with the custom PostgreSQL setting `miru.writer`. A trigger function reads it with `current_setting('miru.writer', true)` and logs it. The `true` argument makes the call return instead of raising when the setting is missing.

The value an unmarked write reads depends on the session's history. A brand-new connection reads NULL. A session that once ran `SET LOCAL miru.writer = ...` reads `''` after that transaction ends. A session also reads `''` after `Timekeeping::LegacyWriterMark` puts a NULL mark back with `set_config('miru.writer', '', true)`. Pooled connections are reused across specs, so the same unmarked write can log NULL in one run and `''` in another.

## Solution

- Treat `''` and NULL as the same thing: no writer marked this write. The writer-log trigger stores `NULLIF(current_setting('miru.writer', true), '')`, so an unmarked write always logs NULL. Keep that NULLIF; it is deliberate, not leftover code.
- Apply the same rule in any new reader of a session marker. Do not write a check that only tests `IS NULL`.
- To test the rule, build the `''` state yourself on a connection outside the pool. Use `ActiveRecord::Base.connection_pool.db_config.new_connection`, run `BEGIN`, `SET LOCAL miru.writer = 'projection'`, `COMMIT`, and then assert that `current_setting('miru.writer', true)` reads `""` before the unmarked write. That assertion makes the spec fail loudly if the server behaves differently, instead of passing without testing anything.
- Also cover the mid-transaction case: `set_config(..., '', true)` followed by an unmarked write in the same transaction.
- Disconnect the fresh connection and remove the trigger in `ensure`.

## Why it matters

A test that uses a fresh connection reads NULL, so it passes with or without the NULLIF. It cannot catch someone removing the conversion. Without the conversion, exact `writer: nil` row assertions depend on which spec last used the pooled session. The cost of the rule is small: the log no longer shows "never marked" apart from "mark cleared", and the guard never uses that difference. NULL, empty and unknown writers are still violations in every state.

## Evidence

- PR #464 rewrites the comment above `CREATE_LOG_TABLE_SQL` in `spec/support/timekeeping/writer_log.rb`. The comment now says the function turns '' into NULL on purpose, and names both sources of '': an ended SET LOCAL and `Timekeeping::LegacyWriterMark` restoring a NULL mark with set_config.
- PR #464 adds two examples to `spec/meta/timekeeping_writer_log_spec.rb`. The first runs SET LOCAL in a committed transaction on a fresh connection, asserts `current_setting('miru.writer', true)` equals `""`, then expects the logged row to be `{ writer: nil, company_id:, op: "UPDATE" }` and a violation in the legacy, timekeeping and rollback states. The second expects writers `["legacy_gateway", nil]` after `set_config('miru.writer', '', true)` inside one transaction.
- The PR #464 description reports that removing the NULLIF made both new examples fail, along with three existing pooled-connection examples.

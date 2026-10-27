---
module: Timekeeping gateway
date: 2026-10-26
problem_type: convention
component: service_layer
severity: medium
evidence_grounding: anchored
grounding_evidence: app/services/timekeeping/gateway.rb as_legacy_writer reads current_setting first, restores it with set_config(..., true), and rescues ActiveRecord::StatementInvalid in restore_writer_after_failure; spec/services/timekeeping/gateway_spec.rb checks caller_mark is back after a successful and a failed create inside a caller transaction.
audience: both
related_components:
  - PostgreSQL
  - Timekeeping::ProjectionConsumer
tags:
  - set-local
  - session-settings
  - nested-transactions
  - writer-marker
applies_when:
  - Code runs SET LOCAL to mark which writer made a change
  - That code can be called inside a transaction another caller opened
---

# Restore a SET LOCAL marker when you join a caller's transaction

## Context

The entry gateway marks legacy writes with `SET LOCAL miru.writer = 'legacy_gateway'`. A later database guard reads that setting to tell legitimate writes from writes that bypass the gateway.

`ActiveRecord::Base.transaction` does not open a new database transaction when one is already open. It joins the outer one. In PostgreSQL, a `SET LOCAL` value lasts until the outermost transaction ends. So when the gateway runs inside a caller's transaction, every statement the caller runs after the gateway returns would still carry the gateway's mark.

## Solution

Treat the marker as borrowed state:

1. Read the current value first: `SELECT current_setting('miru.writer', true)`.
2. Run the fixed `SET LOCAL` literal.
3. After the write, put the old value back with `SELECT set_config('miru.writer', ?, true)`, binding the value through `sanitize_sql_array`.
4. Restore on failure too, because the caller may rescue the error and keep using the transaction.
5. When the failure was a SQL error, the transaction is aborted and the restore itself fails. Rescue `ActiveRecord::StatementInvalid` from the restore only, so the write's own error reaches the caller. The rollback clears the setting anyway.

Test it inside a transaction the spec opens: set a caller value, call the gateway, and read the setting before the outer transaction ends. Reading after rollback proves nothing.

## Why it matters

A marker that leaks makes the database guard trust writes that never went through the gateway, which defeats the guard. A restore that raises over the original error hides a validation failure behind a confusing "current transaction is aborted" message.

## Evidence

PR #170 adds `as_legacy_writer`, `restore_writer` and `restore_writer_after_failure` in `app/services/timekeeping/gateway.rb`, with `MARK_LEGACY_WRITER_SQL`, `READ_WRITER_SQL` and `RESTORE_WRITER_SQL` as constants. In `spec/services/timekeeping/gateway_spec.rb`, the example "puts back the writer mark of a caller's transaction it joined" sets `caller_mark`, runs a create, and reads `caller_mark` back inside the same transaction. The example "puts back the caller's writer mark when the legacy write fails, keeping the write's own error" sends `duration: -5`, rescues `ActiveRecord::RecordInvalid` inside the transaction, and again reads `caller_mark`. A `committed_data: true` example in the same file reads `legacy_gateway` from inside the write and an empty value after commit.

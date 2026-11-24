---
module: spec/integration/timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/timekeeping/section_9_3_live.rb
  - RecoverInvoiceOperationIntentsJob
tags:
  - crash-simulation
  - fork
  - sigkill
  - recovery
  - transactions
applies_when:
  - A spec must leave a transaction open and uncommitted, as a process crash would
  - A spec tests recovery of work whose process died before it recorded its failure
---

# Simulate a crash with a forked child and SIGKILL, not a killed thread

## Context

Recovery specs need the state a real crash leaves behind. For an invoice save, that means the intent is still `pending`, the transaction rolled back, and no failure was recorded.

Killing a Ruby thread does not produce that state. `Thread#kill` still runs the thread's ensure blocks, and the rollback still runs the transaction's `after_rollback` callback. In this codebase those paths call `record_failure` and mark the intent `failed`. The spec would then test a handled failure while its name says crash.

## Solution

Fork the test process and kill the child with SIGKILL. SIGKILL runs no Ruby code in the child. `section_9_3_crash_at_checkpoint` in PR #596 does it this way:

1. **Fork and pass a checkpoint.** The child runs the save. It receives a callable that the save calls at the point where the crash belongs, such as after a `prepared` answer or after the abort outbox row is written.
2. **Report and park.** At the checkpoint, the child writes its database backend pid to a pipe and calls `sleep`, with its transaction still open.
3. **Check the checkpoint before the kill.** The parent reads the pid with a deadline (`wait_readable`). It confirms that backend holds the invoice's advisory lock. Then it sends `Process.kill(:KILL, child)` and `Process.wait`.
4. **Wait for the server, not only the process.** The parent polls `pg_stat_activity` until the backend pid is gone. Only then has PostgreSQL rolled back the open transaction and freed its locks. Assert after this, not right after the kill.
5. **Keep the child out of the parent's cleanup.** Every way out of the child ends in `Process.exit!(false)`, so it never runs RSpec's at_exit hooks or the parent's ensure blocks. The parent's ensure kills and reaps any child still alive, and it ignores `ESRCH` and `ECHILD`.
6. **Send only the error class across the pipe.** A child error message can hold a database URL or a secret. The parent raises `CrashChildFailed` with the class name only.

The child uses its own connection pools after the fork, so it never touches a connection the parent holds.

## Why it matters

If a thread kill stands in for a crash, the recovery path is never exercised. The intent is already `failed` before recovery runs, so the spec passes even if recovery is broken. If the child is not ended with `exit!`, it runs the parent's teardown a second time against shared databases. If the parent asserts before the backend is gone, the old transaction can still hold locks and rows.

## Evidence

- PR #596, `spec/support/timekeeping/section_9_3_live.rb`: adds `section_9_3_crash_at_checkpoint`. Its comment says a killed Ruby thread would run ensure blocks and the `after_rollback` callback that record the failure, and that SIGKILL runs nothing in the child.
- The same file adds `section_9_3_run_crash_child`, which ends every path in `Process.exit!(false)`. It also adds `section_9_3_read_checkpoint`, which passes only the error class, and `section_9_3_reap_crash_child`. The parent polls `BACKEND_PRESENT_SQL` until the killed backend leaves `pg_stat_activity`.
- `spec/integration/timekeeping/section_9_3_spec.rb` in PR #596: both crash examples assert the intent is still `pending` after the kill. They then run `section_9_3_recover_now` and assert `failed`. The failure-transaction example also asserts no abort row survived the kill.

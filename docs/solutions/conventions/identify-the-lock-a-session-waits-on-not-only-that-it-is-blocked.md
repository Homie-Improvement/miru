---
module: spec/integration/timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/committed_data.rb
  - spec/support/timekeeping/section_9_3_live.rb
tags:
  - concurrency
  - blocked-by
  - pg-locks
  - advisory-lock
  - lock-discrimination
applies_when:
  - A spec must fail when one specific lock is removed
  - The code under test takes more than one lock, or writes rows before it takes the lock under test
  - Several sessions wait on one held row
---

# Identify the lock a session waits on, not only that it is blocked

## Context

Concurrency specs in this repository prove a wait with `blocked_by?` from `spec/support/committed_data.rb`. That helper asks PostgreSQL's `pg_blocking_pids` whether one backend waits on another. It answers true for any lock between them: an advisory lock, a row lock, or the row lock a foreign-key check takes.

So a spec that wants to prove "this lock serializes these callers" can stay green after that lock is removed. Some other lock still makes the second caller wait. The spec has stopped testing what its name says.

PR #596 hit this in two places:

- **Two saves of one invoice.** Each save writes its rows during `before_save`. It takes the invoice-identity advisory lock only later, when the reservation boundary flushes. If both saves update the same line or the invoice row, the second save waits on that row lock. It never reaches the advisory lock.
- **Two prepares of one entry.** The test holds the entry row `FOR UPDATE`. A reservation INSERT also waits on that held row, because its foreign key to `entries` locks the referenced row. A blocking chain of INSERTs can look like the entry lock working.

## Solution

Prove the wait, then prove which lock it is.

1. **Design the callers so they share only the lock under test.** In the two-saves example, the draft has two separate lines. Each save points a different line at a new entry with the same rate and quantity. Totals do not change, so neither save writes the `invoices` row or the other's line.
2. **For an advisory lock, look for the ungranted row in `pg_locks`.** A bigint advisory key is listed with its high 32 bits in `classid`, its low 32 bits in `objid`, and `objsubid = 1`. Rebuild the key the way the product builds it and compare:

   ```sql
   SELECT EXISTS (
     SELECT 1 FROM pg_locks
     WHERE pid = $1 AND locktype = 'advisory' AND objsubid = 1 AND granted = $2
       AND ((classid::bigint << 32) | objid::bigint) = hashtextextended($3, 0)
   )
   ```

   Pass the key from the product's own method (`Invoices::OperationLock.key`), not a copy of how it is built.
3. **For a row lock, check the waiting statement's text.** Read `query` from `pg_stat_activity` for each waiter. Accept the wait only when the statement is the locking SELECT, here `/\ASELECT "entries"\."id" FROM "entries" .* FOR UPDATE\b/m`. This rejects an INSERT that waits on its foreign-key check.
4. **Find queued waiters through the whole chain.** When two sessions wait for one held row, only the first is blocked by the holder. The second is blocked by the first waiter. A recursive query over `pg_blocking_pids` finds both. Then require at least one waiter that the holder blocks directly.

## Why it matters

A lock-discrimination spec is only worth having if removing the lock turns it red on an assertion. If an unrelated row lock or foreign-key wait keeps `blocked_by?` true, the spec fails later in an unrelated way, or not at all. A reviewer reading "the second save waits" cannot tell this apart from a real proof. Check the shared rows and the waiting statement whenever a spec claims a specific lock.

## Evidence

- PR #596, `spec/support/timekeeping/section_9_3_live.rb`: adds `OPERATION_LOCK_SQL`, which decodes the advisory key from `classid`, `objid` and `objsubid = 1`. It also adds `section_9_3_operation_lock?`, whose comment says `blocked_by?` alone cannot tell this wait from a wait on a row lock.
- The same file adds `TIMEKEEPING_WAITERS_SQL`, a recursive query whose comment says the second waiter waits on the first waiter, not on the holder. PR #617 later renamed it `WAITERS_SQL` and moved its use into `section_9_3_waiters(database_name, holding_pid, count:, within:)`. `section_9_3_timekeeping_waiters` and `section_9_3_monolith_waiters` call it for each database. It adds `ENTRY_LOCK_QUERY` and `section_9_3_timekeeping_waiting_on_entry_lock?` to reject waits from a later statement such as the reservation INSERT.
- `spec/integration/timekeeping/section_9_3_spec.rb` in PR #596: the two-saves example repoints two different existing lines, keeping rate and quantity. It asserts both `blocked_by?(second_pid, first_pid)` and `section_9_3_operation_lock?(..., granted: false)`. The two-prepares example asserts `entry_lock_waiters` equals `waiters`, with a comment about the foreign-key wait.
- The author ran the `ENTRY_LOCK_QUERY` pattern against both statements. It matched the entry-locking SELECT and did not match the reservation INSERT.

## Removal record

Each run below removed one mechanism in the working tree, ran the examples that depend on it, and restored the file. No removal was committed. On the restored tree every example listed passed. Live runs used `TIMEKEEPING_LIVE=1` with the environment of the `timekeeping-runtime-live` CI job. The section 9.3 examples ran for both seeded companies, "Fork & Leaf Salads" and "Copper Kettle Bakery", and both failed on every run.

**Search.** `grep -rlF '<pattern>' spec timekeeping/spec` for each of `blocked_by?(`, `OperationLock`, `hold_at: :rows_locked`, `BillingFence` and `settle`. Most `BillingFence` hits are refusal specs, and most `settle` hits are the unrelated payment `Invoice#settle!`. The `blocked_by?(` hits, which are the examples that prove a wait, were:

- `spec/db/committed_data_mode_spec.rb`
- `spec/integration/timekeeping/handoff_concurrency_spec.rb`
- `spec/integration/timekeeping/section_9_3_spec.rb`
- `spec/jobs/recover_invoice_operation_intents_job_spec.rb`
- `spec/lib/timekeeping/handoff/monolith_admission_spec.rb`
- `spec/models/timekeeping_ownership_concurrency_spec.rb`
- `spec/services/invoices/operation_lock_spec.rb`
- `spec/services/invoices/prepared_reservations_concurrency_spec.rb`
- `spec/services/timekeeping/billing_fence_concurrency_spec.rb`
- `spec/services/timekeeping/gateway_agent_race_spec.rb`
- `spec/services/timekeeping/gateway_fence_concurrency_spec.rb`
- `spec/services/timekeeping/gateway_spec.rb`
- `spec/services/timekeeping/local_owner_agent_race_spec.rb`
- `spec/services/timekeeping/local_owner_concurrency_spec.rb`
- `spec/services/timekeeping/local_owner_reservations_spec.rb`
- `spec/services/timekeeping/local_owner_service_commands_spec.rb`
- `spec/services/timekeeping/projection_consumer_spec.rb`
- `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb`
- `timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb`

**Save-path invoice-identity lock.** Removed both `Invoices::OperationLock.acquire!` calls on the save path: `Flush#call` in `app/services/invoices/reservation_boundary.rb` and `lock_current_generation!` in `app/services/invoices/operation_coordinator.rb`. Removing only one leaves the save serialized by the other.

- "Two saves of one invoice start together" (`-e 'Two saves of one invoice start together'`): 1 example, 1 failure. For each company it failed on "the second save should wait on the first save", "the second save should wait on the invoice-identity lock", "both saves should commit; their intents are [\"committed\", \"failed\"]", "the invoice should carry both saves' entries" and "the invoice should hold exactly its new entries committed".
- `spec/services/invoices/operation_lock_spec.rb` stayed green. It calls `OperationLock.acquire!` directly, so it does not depend on the save-path call sites.

**Timekeeping entry lock.** Removed `.lock("FOR UPDATE")` from `lock_entries` in `timekeeping/app/services/timekeeping/reservation_operations.rb`. The monolith copies of `lock_entries` were left alone, because the live example runs after cutover against the Timekeeping server.

- "Two invoices prepare one entry at once": 1 example, 1 failure. For each company it failed on "both prepares should wait in Timekeeping's entry-locking SELECT ... FOR UPDATE; waiting sessions [845, 924], of which in that SELECT []" (the prepares waited in the reservation INSERT's foreign-key check instead), "the two prepares answered [200]" and "the refused prepare should name provisional_elsewhere; saw {}".
- `timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb`: 8 examples, 5 failures. Lines 86 and 257 failed with "the second request never waited on the first one's lock". Lines 160, 192 and 221 failed with "the other writer never waited on the held operation's lock".

**Recovery lock.** Removed `Invoices::OperationLock.acquire!` from `RecoverInvoiceOperationIntentsJob#resolve` in `app/jobs/recover_invoice_operation_intents_job.rb`.

- "Crash after prepare, before the invoice commits": 1 example, 1 failure. For each company it failed on "recovery should wait on the paused save's lock", "recovery beside a live save should change nothing; before {...}, after {...}" and "the released save should commit". The `blocked_by?` check alone was enough here: with the lock gone, recovery did not wait at all and failed the live save's intent.
- `spec/jobs/recover_invoice_operation_intents_job_spec.rb`: 15 examples, 4 failures. Lines 250 and 382 failed with `Expected "failed" to eq "pending".`. Line 288 failed with `Expected false to equal true.` on `expect(waited).to be(true)`. Line 333 failed with `Invoices::OperationErrors::IntentNotPending`, raised by the released save because recovery had already failed its intent.

**Billing fence.** Removed `.lock("FOR SHARE")` from `Timekeeping::BillingFence.admit!` in `app/services/timekeeping/billing_fence.rb`.

- `spec/services/timekeeping/billing_fence_concurrency_spec.rb`: line 9 failed with "the handoff update never waited on the billing transaction's lock", and line 44 failed with "the billing transaction never waited on the handoff update's lock".
- `spec/lib/timekeeping/handoff/monolith_admission_spec.rb`: line 340 failed with `Expected false to equal true.` on `expect(blocked_by?(fence_pid, late_pid, within: 3)).to be(true)`.
- `spec/integration/timekeeping/handoff_concurrency_spec.rb`, "makes step 1 of a rollback wait for an invoice save paused after prepare, and settles the save before the freeze": 1 example, 1 failure, "Fork & Leaf Salads: step 1 of the rollback did not wait on the save's FOR SHARE lock". The example has no `aggregate_failures`, so a rerun with the company list narrowed to Copper Kettle Bakery, then restored, gave "Copper Kettle Bakery: step 1 of the rollback did not wait on the save's FOR SHARE lock". The same example also depends on the settling phase, below.
- `spec/models/timekeeping_ownership_concurrency_spec.rb` and `spec/services/timekeeping/gateway_fence_concurrency_spec.rb` stayed green. They prove other locks on the ownership row, not the billing fence's share lock.

**Billing fence admission refusal.** Removed `|| ownership.admission_closed?` from `raise OwnershipMoving if ownership.nil? || ownership.admission_closed?` in `Timekeeping::BillingFence.admit!` (`app/services/timekeeping/billing_fence.rb`). This is the refusal that the handoff's step 1 turns on when it records `close_admission`. The `FOR SHARE` in the same method, which has its own run under **Billing fence** above, was left alone, and so was the refusal of a missing ownership row.

- `spec/integration/timekeeping/handoff_concurrency_spec.rb -e 'refuses invoice create, update and discard'`, before strengthening: 1 example, 1 failure, "Got 6 failures and 1 other error from failure aggregation block "billing writes held at after_close_admission"". The six failures were all "Fork & Leaf Salads create at after_close_admission" and "Fork & Leaf Salads update at after_close_admission", on the 503 status, the `ownership_moving` reason and the unchanged billing digest. The discard raised `Invoices::OperationErrors::PrepareRetryable: stale_generation` through the request, which ended the aggregate block, so Copper Kettle Bakery was never checked. That run proved nothing for the second company.
- After strengthening: 1 example, 1 failure, "Got 16 failures from failure aggregation block "billing writes held at after_close_admission"". For each company, create and update each failed on the status, the reason and the digest, with the messages "Fork & Leaf Salads create at after_close_admission", "Fork & Leaf Salads update at after_close_admission", "Copper Kettle Bakery create at after_close_admission" and "Copper Kettle Bakery update at after_close_admission". The discard failed for each company with "Fork & Leaf Salads discard at after_close_admission raised #<Invoices::OperationErrors::PrepareRetryable: stale_generation> instead of answering 503 ownership_moving" and the same message for "Copper Kettle Bakery", and on the digest check with "... discard at after_close_admission". So no write got the 503 refusal. The discard raised from Timekeeping's generation check instead of answering, and the company's billing rows still changed. The example stopped at `after_close_admission` and never reached `after_settle`.
- The strengthening: `concurrency_expect_billing_writes_refused` now keeps an error a write raises as a value, through `concurrency_request_error`, and reports it as a failure, so one raising write no longer ends the check of the remaining writes and companies.

**Handoff settling phase.** Removed `settle_integration.settle!(generation: @generation)` from `Runner#settle` in `lib/timekeeping/handoff/runner.rb`.

- `spec/integration/timekeeping/handoff_concurrency_spec.rb`, "makes step 1 of a rollback wait for an invoice save paused after prepare, and settles the save before the freeze": 1 example, 1 failure, "Fork & Leaf Salads: at the freeze the in-flight operation was not settled (The settle step did not finish; resume or abort the handoff)". That example has no `aggregate_failures`, so the first company's failure stopped the loop. A rerun with the company list narrowed to Copper Kettle Bakery, then restored, failed with the same message for "Copper Kettle Bakery". Select this example with `-e`: selecting it by line number picked the neighbouring example.
- Among the examples in `spec/integration/timekeeping/section_9_3_spec.rb`, none depends on the billing fence or the settling phase. The fence-dependent examples in other files are listed under **Billing fence** above.

**Gateway agent locks.** Removed `agent.lock!` from `Timekeeping::Gateway#detach_agent_entries` in `app/services/timekeeping/gateway.rb` and `.lock("FOR SHARE")` from `TimesheetEntry#validate_agent_exists` in `app/models/timesheet_entry.rb`, in three runs: both at once, then each alone. The agent `FOR SHARE` in `Timekeeping::ProjectionConsumer#refuse_foreign_agents!` was left alone, because it is not on the Gateway create or destroy path.

- Both removed, `spec/services/timekeeping/gateway_agent_race_spec.rb`: 2 examples, 2 failures. "makes an agent destroy wait for a forwarded agent create ..." failed with "the agent destroy did not wait for the create holding the agent lock". "refuses a forwarded agent create that waited on an agent destroy ..." failed with "the create never waited on the agent row the destroy holds".
- Only `agent.lock!` removed: 2 examples, 1 failure. The destroy example failed with "the agent destroy should wait in agent.lock! (SELECT ... FROM "agents" ... FOR UPDATE) in Timekeeping::Gateway#detach_agent_entries; it waited in "DELETE FROM \"agents\" WHERE \"agents\".\"id\" = $1"". Before the spec was strengthened, this run's only red was an `ActiveRecord::RecordNotFound` error: the destroy's own DELETE still waited on the create's share lock, but after the detach had already run. The example now reads the destroy's waiting statement from `pg_stat_activity`. The refusal example stayed green, because it waits on the share lock, not on `agent.lock!`.
- Only the `FOR SHARE` removed: 2 examples, 2 failures, with the same two messages as the run with both removed.
- Before the strengthening, the run with both removed also surfaced only as errors, from the worker threads. The examples now check `blocked` before they join the threads, and drop worker errors in their `ensure`.

**Gateway legacy-create lock.** Removed `LocalOwner::WriteSteps.lock_key(LEGACY_CREATE_LOCK, *scope.values)` from `Timekeeping::Gateway#legacy_create` in `app/services/timekeeping/gateway.rb`, the only `LEGACY_CREATE_LOCK` acquisition. `lock_key(LEGACY_ENTRY_WRITE_LOCK, ...)` was left alone, because it is on the legacy update and delete path.

- `spec/services/timekeeping/gateway_spec.rb -e 'two concurrent legacy creates with the same idempotency key'`, before strengthening: 1 example, 1 failure, "expected [1, #<ActiveRecord::RecordNotUnique ...>] to be a kind of Integer". The retry still waited, on the receipt INSERT's unique index, so this red was only an error and does not count.
- After strengthening, the same run: 1 example, 1 failure, "the retry should wait on the legacy-create receipt lock (LocalOwner::WriteSteps.lock_key(LEGACY_CREATE_LOCK, ...) in Timekeeping::Gateway#legacy_create); the first create never took it, and the retry waited in "INSERT INTO \"legacy_create_receipts\" (...) VALUES ($1, ..., $10) RETURNING \"id\""". The example records the two keys `lock_key` passes to `advisory_lock`, and reads `pg_locks` for an ungranted advisory row with those keys, so the check never takes the lock or rebuilds its key.

**Projection consumer ownership lock.** Removed `.lock("FOR SHARE")` from `TimekeepingOwnership.lock("FOR SHARE").find(...)` in `Timekeeping::ProjectionConsumer#refuse_stale_generations!` (`app/services/timekeeping/projection_consumer.rb`), the only ownership lock on the delivery path. The ownership `FOR SHARE` copies in `gateway.rb`, `billing_fence.rb`, `local_owner/write_steps.rb`, `invoices/prepared_reservations.rb` and `lib/timekeeping/handoff/runner.rb` were left alone, because a delivery does not reach them.

- `spec/services/timekeeping/projection_consumer_spec.rb -e 'makes the ownership flip wait'`: 1 example, 1 failure, "the ownership flip never waited on the paused delivery's lock".

**Projection consumer entry lock.** Removed both entry `FOR UPDATE`s in `app/services/timekeeping/projection_consumer.rb`: `lock_stored_rows` and the fallback read in `upsert`.

- `-e 'keeps v3 when a v2 delivery'`: 1 example, 0 failures, on each of 4 runs. No session waits on a lock in this example, so it proves the version guard instead. Its run is under **Projection version guard** below.

**Projection version guard.** Removed the condition `WHERE timesheet_entries.version < EXCLUDED.version` from the `ON CONFLICT ... DO UPDATE` in `Timekeeping::ProjectionConsumer#upsert_sql` (`app/services/timekeeping/projection_consumer.rb`). The company condition below it became the `WHERE`, so the statement still parsed and the company guard stayed. The version compare in `applying_items` was left alone: it only chooses which snapshots the project and agent checks look at, and `write` upserts every item whatever it returns, so it never stops a write.

- `spec/services/timekeeping/projection_consumer_spec.rb -e 'keeps v3 when a v2 delivery'`: 1 example, 1 failure, on each of 2 runs. It failed on `expect(older.value).to eq(rules_ignored)` with `Expected [200, { "applied" => 1, "ignored" => 0 }] to eq [200, { "applied" => 0, "ignored" => 1 }].`, as printed by the `super_diff` matcher output that `spec/spec_helper.rb` loads. The paused v2 delivery overwrote the committed v3 row. v2 tries to lock entry 91_006 before the row exists, so it holds no row lock, and v3 inserts and commits before v2 writes. The version guard in the statement is the only thing that keeps v3.

**Timekeeping receipt-key lock.** Removed `WriteSteps.lock_key(...)` from `Timekeeping::EntryWriter#lock_receipt_key` in `timekeeping/app/services/timekeeping/entry_writer.rb`. The other `lock_key` calls were left alone. `ServiceCommands#run` and `ReservationOperations` take their own locks, which entry writes do not reach. `ServiceCommands.lock_agent`, which `EntryWriter#names_detached_agent?` calls, is the agent lock, a different mechanism with its own run under **Timekeeping agent lock** below.

- `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb`: 10 examples, 3 failures. "answers two identical PATCHes with one key ...", "answers two identical DELETEs with one key ..." and "answers two creates with one key and different bodies ..." each failed with "the second request never waited on the first one's lock".

**Timekeeping outbox lock.** Removed both acquisitions of `pg_advisory_xact_lock(OUTBOX_LOCK_KEY)`: in `Timekeeping::WriteSteps.write_outbox` (`timekeeping/app/services/timekeeping/write_steps.rb`) and in `OutboxSnapshot.lock_for_insert!` (`timekeeping/app/models/outbox_snapshot.rb`).

- `entry_writer_race_spec.rb`: 10 examples, 1 failure. "makes a write to another entry, with another key, wait for the first write's outbox commit" failed with "the second request never waited on the first one's lock".

**Timekeeping admission share lock.** Removed `FOR SHARE` from `Timekeeping::Admission.locked_generation` (`timekeeping/app/models/timekeeping/admission.rb`), which both `EntryWriter` and `ServiceCommands` call. `Admission.locked_state` was left alone, because entry writes do not call it.

- `entry_writer_race_spec.rb`: 10 examples, 2 failures. "makes a fence wait until the write that read the admitted generation commits" failed with "the second request never waited on the first one's lock". "a fence that times out behind an admitted write ..." failed with "expected ActiveRecord::LockWaitTimeout but nothing was raised"; its teardown then hit a deadlock while truncating, which is an after-effect of the unfenced write and not counted.
- `spec/integration/timekeeping/handoff_concurrency_spec.rb -e "makes a rollback's step-1 fence wait for a running Timekeeping entry update"`, run live: 1 example, 1 failure, "Fork & Leaf Salads: the rollback's step-1 fence did not wait on the entry update". This share lock is what the step-1 fence's `UPDATE` of the admission row waits on while an entry update holds it. The example has no `aggregate_failures`, so a rerun with the company list narrowed to Copper Kettle Bakery, then restored, gave "Copper Kettle Bakery: the rollback's step-1 fence did not wait on the entry update".
- "refuses with stale_generation a write that reads the generation after a fence commits" stayed green. The fence commits before the write reads the generation, so nothing waits: it proves the generation check, not the share lock. Its run is under **Timekeeping generation check** below.

**Timekeeping generation check.** Made the `WriteSteps.generation_matches?` check in `Timekeeping::EntryWriter#write` never refuse. `ServiceCommands#run` has its own copy of the check, which was left alone, because entry writes do not reach it.

- `entry_writer_race_spec.rb -e 'refuses with stale_generation'`, before strengthening: 1 example, 1 failure, raised as `ActiveRecord::NotNullViolation` ("null value in column "generation" of relation "outbox_snapshots""). The outbox column stopped the write only after the entry was written, so this red was only an error and does not count.
- After strengthening: 1 example, 1 failure, "the write past the fence should be refused by the generation check (WriteSteps.generation_matches? in EntryWriter#write); it ended with #<ActiveRecord::NotNullViolation: ...>". The example now keeps the writer's error as a value and checks that the outcome is a refusal before reading its status.

**Timekeeping agent lock.** Removed both acquisitions of the agent lock: `ServiceCommands.lock_agent` in `Timekeeping::EntryWriter#names_detached_agent?`, and `WriteSteps.lock_key(request.company_id, command.fetch(:lock), request.target_id)` in `Timekeeping::ServiceCommands#run` (`timekeeping/app/services/timekeeping/service_commands.rb`), whose detach lock is `"agent"`. The receipt-key `lock_key` call just above it was left alone.

- `entry_writer_race_spec.rb -e 'makes a detach wait'`: 1 example, 1 failure, "the detach finished while the create held the agent lock (ServiceCommands.lock_agent in EntryWriter#names_detached_agent?)". Removing only the `lock_agent` call gave the same failure. The example also checks, from `pg_locks` and the `lock_key` parts the detach passed, that the detach waits in `WriteSteps.lock_key(company_id, "agent", agent_id)`.

**Timekeeping detach marker.** Replaced the `ServiceCommands.agent_detached?` call in `Timekeeping::EntryWriter#names_detached_agent?` with `false`. It is the only caller.

- `entry_writer_race_spec.rb`: 10 examples, 2 failures. "refuses a create held before the agent lock once a detach of the agent committed meanwhile" failed on `expect([created.status, JSON.parse(created.body)]).to eq([404, { "reason" => "not_found" }])`, getting `[201, {"agent_id" => 4, ...}]`. "accepts a create built after a committed detach whose agent still exists, and still refuses one built before it" failed on the same expectation for the late create, also getting a 201. Neither example waits on a lock: the detach commits first, so the stored marker is what refuses the create.

**`blocked_by?` self-test holder lock.** Removed `.lock("FOR UPDATE")` from `TimekeepingOwnership.lock("FOR UPDATE").find(...)` in `hold_ownership_row_for_lock_wait_spec` (`spec/db/committed_data_mode_spec.rb`). This lock belongs to the spec, not the product: the helper takes it only so that the `blocked_by?` self-test has a real wait to observe. The file's other examples take no lock of their own and were left alone.

- `-e 'reports a lock wait only for the waiting pid and the pid that holds the lock'`: 1 example, 1 failure, `Expected false to equal true.` on `expect(really_blocked).to be(true)`.
- `-e 'counts a lock wait only when the named holder is the one blocking the named waiter'`: 1 example, 1 failure, `Expected false to equal true.` on `expect(really_blocked).to be(true)`.
- `-e 'does not report a contender that has not sent its query as blocked'`: 1 example, 1 failure, `Expected false to equal true.` on `expect(after_query).to be(true)`.
- Each message is the one-line form that the `super_diff` matcher output, loaded by `spec/spec_helper.rb`, prints. Without the lock, the waiter's `update_all` found nothing holding the row and never waited.

**Prepared-reservation entry lock.** Removed `.lock(ROW_LOCK)` from `Timekeeping::LocalEntry.where(...).order(:id).lock(ROW_LOCK).pluck(:id)` in `Invoices::PreparedReservations#lock_entries` (`app/services/invoices/prepared_reservations.rb`), the only entry lock the adapter takes; `prepare`, `admit`, `commit`, `abort` and `mark_billed` all call it. The local-owner copies (`ReservationOperations#lock_entries`, `ServiceCommands`) and the Timekeeping copy in `timekeeping/app/services/timekeeping/reservation_operations.rb` were left alone, because the adapter never calls them.

- `spec/services/invoices/prepared_reservations_concurrency_spec.rb`: 8 examples, 2 failures. "a prepare waiting behind an abort re-reads the entry as free ..." failed with "the prepare never waited on the abort's entry lock". "a prepare of the same entry for another invoice waits on the entry lock ..." failed on `expect(lost&.state).to eq("refused")` with `Expected "retryable" to eq "refused".`, as printed by the `super_diff` matcher output that `spec/spec_helper.rb` loads. Its `blocked_by?` check still passed: the second prepare waited on the one-provisional-per-entry index instead, and answered retryable.
- "a prepare waiting behind a rolled-back prepare of the same entry wins ..." (the rollback control), before strengthening, stayed green. Without the entry lock the second prepare still waited, on the one-provisional-per-entry index, and still won once the first rolled back.
- After strengthening, `-e 'rolled-back prepare'`: 1 example, 1 failure, "the second prepare should wait in the entry lock (.lock(ROW_LOCK) in Invoices::PreparedReservations#lock_entries); it waited in "INSERT INTO \"reservations\" (\"company_id\",\"entry_id\",\"invoice_id\",\"state\",\"disposition\",\"operation_id\",\"invoice_operation_id\",\"created_at\") VALUES (1, 1, 2, 'provisional', 'active', '...', 2, '...')"". The example now reads the waiting session's statement with `committed_data_session_statement` and matches it against `TimekeepingSection93Live::ENTRY_LOCK_QUERY`, which also matches the monolith statement because `Timekeeping::LocalEntry` uses the `entries` table.

**Prepared-reservation operation-row lock.** Removed `.lock` from `operation = find_operation(request).lock.first` in `Invoices::PreparedReservations#finish` (`app/services/invoices/prepared_reservations.rb`), the only lock on the `invoice_operations` row in the adapter. The ownership share lock and the entry lock taken later in the same method were left alone; each has its own run here.

- `spec/services/invoices/prepared_reservations_concurrency_spec.rb`: 8 examples, 2 failures. "an abort waiting behind a commit of the same operation leaves it committed and changes nothing" failed on `expect([lost&.state, lost&.counts]).to eq(["aborted", {}])` with `Expected ["aborted", { dropped: 0 }] to eq ["aborted", {}].`. "a commit waiting behind an abort of the same operation leaves it aborted ..." failed on `expect([lost&.state, lost&.counts]).to eq(["committed", {}])` with `Expected ["committed", { reserved: 0, released: 0 }] to eq ["committed", {}].`. In both the `blocked_by?` check still passed: the losing finish still waited on the first one, on a lock taken later in `finish`, but it had already read the operation as prepared, so it ran its own finish with empty work instead of answering the settled state with empty counts.
- "a settling commit blocked on its operation row already holds the ownership row ..." stayed green. Its own holder locks the operation row, and without the lock in `finish` the commit still waits on that row, later, when it updates the operation; by then it already holds the ownership row. The example proves the ownership lock order, and its run is under **Prepared-reservation ownership share lock** below.

**Prepared-reservation ownership share lock.** Removed `.lock(OWNERSHIP_LOCK)` (`"FOR SHARE"`) from `TimekeepingOwnership.lock(OWNERSHIP_LOCK).find_by(...)` in `Invoices::PreparedReservations#locked_ownership` (`app/services/invoices/prepared_reservations.rb`), which `prepare`, `admit`, `mark_billed` and `finish` all call. The ownership `FOR SHARE` copies in `local_owner/write_steps.rb`, `billing_fence.rb`, `gateway.rb`, `projection_consumer.rb` and `lib/timekeeping/handoff/runner.rb` were left alone, because the adapter does not reach them.

- `spec/services/invoices/prepared_reservations_concurrency_spec.rb`: 8 examples, 2 failures. "stop_applying! waits for an admitted settling commit through the prepared adapter ..." failed with "stop_applying! did not wait for the admitted settling commit". "a settling commit blocked on its operation row already holds the ownership row, so stop_applying! waits behind it" failed with "stop_applying! did not wait for the commit that was already admitted".

**One-prepared-per-invoice index.** Dropped `index_invoice_operations_one_prepared_per_invoice` in the monolith test database `miru_web_test` with `DROP INDEX index_invoice_operations_one_prepared_per_invoice`. The index of the same name in the Timekeeping database was left alone, because the adapter writes only to the monolith. No migration and no `db/schema.rb` line was changed.

- `-e 'one-prepared index'`: 1 example, 1 failure. "a prepare of the same invoice on another entry waits on the one-prepared index and answers unresolved_operation with no writes" failed on `expect([lost&.state, lost&.reason]).to eq(["retryable", "unresolved_operation"])` with `Expected ["prepared", nil] to eq ["retryable", "unresolved_operation"].`. Without the index the second prepare stored a second prepared operation for the invoice. Its `blocked_by?` check still passed, so the answer, not the wait, is what proves the index here.
- Restored with `CREATE UNIQUE INDEX index_invoice_operations_one_prepared_per_invoice ON public.invoice_operations USING btree (company_id, invoice_id) WHERE ((state)::text = 'prepared'::text)`, the definition `pg_indexes` reported before the drop. `pg_indexes` then listed the index with that same definition, and the example passed again: 1 example, 0 failures.

**Local-owner admitted-generation share lock.** Removed `.lock(lock)` (default `SHARED_OWNERSHIP_LOCK`, `"FOR SHARE"`) from `TimekeepingOwnership.lock(lock).find_by(...)` in `Timekeeping::LocalOwner::WriteSteps.admitted_generation` (`app/services/timekeeping/local_owner/write_steps.rb`). Its only caller is `LocalOwner#admitted_generation`, which entry writes read. The NOWAIT read in `WriteSteps.locked_ownership_nowait`, which reservation operations and service commands use, was left alone; it has its own run below. The ownership `FOR SHARE` copies in `invoices/prepared_reservations.rb`, `billing_fence.rb`, `gateway.rb`, `projection_consumer.rb` and `lib/timekeeping/handoff/runner.rb` were left alone, because entry writes do not reach them.

- `spec/services/timekeeping/local_owner_concurrency_spec.rb`: 8 examples, 2 failures. Line 88, "makes a handoff update wait until a LocalOwner update paused after the generation check commits", failed with "the handoff never waited on the write's share lock on the ownership row". Line 126, "refuses a LocalOwner update that queued behind an uncommitted handoff once the handoff commits", failed with "the write never waited on the uncommitted handoff".

**Local-owner NOWAIT ownership read and queued-update check.** Removed `.lock(NOWAIT_OWNERSHIP_LOCK)` (`"FOR SHARE NOWAIT"`) from `TimekeepingOwnership.lock(NOWAIT_OWNERSHIP_LOCK).find_by(...)` and the line `raise OwnershipQueued, "an ownership update is waiting on the row" if ownership_update_queued?` from `Timekeeping::LocalOwner::WriteSteps.locked_ownership_nowait` (`app/services/timekeeping/local_owner/write_steps.rb`). Its callers are `ReservationOperations` (prepare, commit and abort) and, through `locked_generation_nowait`, `ServiceCommands`. The `admitted_generation` share lock above was left alone, because these writers do not call it. Three runs: both at once, then each alone.

- Both removed, 4 examples, 4 failures:
  - `local_owner_concurrency_spec.rb:270`, "answers a service-route settling commit stale_generation while stop_applying! is queued on the ownership row", failed on `expect(outcome.status).to eq(409)` with `Expected 200 to eq 409.`.
  - `local_owner_concurrency_spec.rb:327`, "makes stop_applying! wait for a settling commit admitted before it, then refuses the same commit as stale", failed with "stop_applying! did not wait for the admitted commit".
  - `local_owner_reservations_spec.rb:1058`, "with an ownership update queued behind a FOR SHARE holder, a prepare answers 409 stale_generation without waiting", failed on `expect(outcome.status).to eq(409)` with `Expected 200 to eq 409.`.
  - `local_owner_service_commands_spec.rb:986`, "mark_billed and detach_entries answer 409 stale_generation without waiting and write nothing", failed with `Expected { mark_billed: [200, { "billed" => 1 }], detach_entries: [200, { "detached" => 1 }] } to eq { mark_billed: [409, { "reason" => "stale_generation" }], detach_entries: [409, { "reason" => "stale_generation" }] }`.
- Only the `FOR SHARE NOWAIT` removed: 4 examples, 1 failure. Line 327 failed with "stop_applying! did not wait for the admitted commit". The other three stayed green, because the queued-update check alone still refused the write.
- Only the `ownership_update_queued?` check removed: 4 examples, 3 failures. Lines 270, 1058 and 986 failed with the same messages as the run with both removed. Line 327 stayed green, because the share lock alone still held `stop_applying!` back. As `ownership_update_queued?`'s comment says, PostgreSQL grants the NOWAIT share read beside the holder while an update is queued, so the check, not the lock, refuses those writes.
- Each `Expected ... to eq ...` line is the one-line form printed by the `super_diff` matcher output that `spec/spec_helper.rb` loads.

**Local-owner outbox lock.** Removed `ApplicationRecord.connection.execute(... "SELECT pg_advisory_xact_lock(?)", LOCK_KEY ...)` from `Timekeeping::EntryOutbox.write` (`app/services/timekeeping/entry_outbox.rb`), the only acquisition of `EntryOutbox::LOCK_KEY` in the monolith. `LocalOwner::OUTBOX_LOCK_KEY` is an alias of the same constant, and `WriteSteps` and `Invoices::PreparedReservations` both write the outbox through `EntryOutbox.write`, so this one edit removed the lock from every writer. The Timekeeping copies in `timekeeping/app/services/timekeeping/write_steps.rb` and `timekeeping/app/models/outbox_snapshot.rb` were left alone, because these specs run in the monolith.

- `local_owner_concurrency_spec.rb:237`, "holds a second writer's outbox row back until a first writer paused after its outbox insert commits": 1 example, 1 failure, "the second write never waited on the first write's outbox lock".

**Local-owner entry row lock.** Removed `.lock("FOR UPDATE")` from `relation.order(:id).lock("FOR UPDATE").pluck(:id)` in `LocalOwner#locked_entries` (`app/services/timekeeping/local_owner.rb`), the only entry lock on the entry update and delete path. The entry `FOR UPDATE` copies in `ReservationOperations#lock_entries` and `ServiceCommands` were left alone, because entry writes do not call them.

- `local_owner_concurrency_spec.rb`, lines 167 and 202: 2 examples, 2 failures. "refuses an employee update that waited on the row lock behind a reservation insert that then commits" and its control "lets an employee update that waited behind a rolled-back reservation insert change the entry" each failed with "the update never waited on the reservation insert's lock on the entry row". The reservation INSERT holds only a key-share lock on the entry, and without the `FOR UPDATE` the update's own row lock does not conflict with it.
- The concurrency file's first example, "refuses to pause at a step LocalOwner does not have", takes no lock and has no run.

**Local-owner advisory locks.** Made `Timekeeping::LocalOwner::WriteSteps.advisory_lock` (`app/services/timekeeping/local_owner/write_steps.rb`) return before it runs `pg_advisory_xact_lock`. Every monolith advisory key on the local-owner path goes through it: `WriteSteps.lock_key`, which `ServiceCommands.lock_agent`, `ServiceCommands#lock_operation_keys`, `ReservationOperations` and `Timekeeping::Gateway` call, and `LocalOwner#lock_receipt_key`, which digests its own key and calls `advisory_lock` directly. Removing only `lock_key` would have left the receipt-key lock in place. `EntryOutbox::LOCK_KEY` does not go through `advisory_lock`; it has its own run under **Local-owner outbox lock** above. Three runs: all advisory locks at once, then the agent lock alone, then the operation-key locks alone.

- All advisory locks removed, `spec/services/timekeeping/local_owner_agent_race_spec.rb` with `local_owner_service_commands_spec.rb:1044` and `:1102`: 12 examples, 6 failures.
  - `local_owner_agent_race_spec.rb:86`, "AE4: a create naming an agent waits on a detach whose receipt is inserted but uncommitted ...", failed with "the create never waited on the detach's agent lock".
  - Line 145, "AE1: a detach waits on a create holding the agent lock and then detaches the committed entry", failed with "the detach never waited on the create's agent lock".
  - Line 234, "makes a local detach wait on an update naming the agent in its body while the update holds the agent lock", failed with "the detach never waited on the update's agent lock".
  - Line 365, "a create waiting on the agent lock holds no lock on the ownership row, so a handoff completes while it waits", failed with "the create never waited on the agent lock".
  - Line 405, "a session taking lock_agent for the agent waits on a create naming that agent until the create commits", failed with "a second session took the agent lock while the create naming the agent held it".
  - `local_owner_service_commands_spec.rb:1044`, "a second session sending one operation_id for another agent waits for the first and answers idempotency_key_reused", failed on `expect(blocked_by?(second_pids.first, first_pids.first)).to be(true)` with `Expected false to equal true.`, the one-line form printed by the `super_diff` matcher output that `spec/spec_helper.rb` loads.
  - `local_owner_service_commands_spec.rb:1102` stayed green: it waits on the entry row lock, and its run is under **Local-owner service-command entry row locks** below.
- Only the agent lock removed: replaced `WriteSteps.lock_key(company_id, AGENT_LOCK, agent_id)` in `ServiceCommands.lock_agent` (`app/services/timekeeping/local_owner/service_commands.rb`) with `nil`. That method is the only agent-lock acquisition; both the detach command and `LocalOwner`'s entry writes call it. 11 examples, 5 failures: the five agent-race examples above, with the same messages. Line 1044 stayed green, because it waits on the operation-key lock.
- Only the operation-key locks removed: replaced both `WriteSteps.lock_key(...)` calls in `ServiceCommands#lock_operation_keys` with `nil`. 11 examples, 1 failure: line 1044, with `Expected false to equal true.` on the same `blocked_by?` expectation. The agent-race examples stayed green, because they wait on the agent lock.
- The other agent-race examples (lines 118, 177, 205, 269 and 305) stayed green in all three runs. None of them has a session wait on another: each lets the detach commit first, so they prove the stored detach marker, not a lock.

**Local-owner service-command entry row locks.** Removed `.lock(ROW_LOCK)` (`"FOR UPDATE"`) from `targets.order(:id).lock(ROW_LOCK).pluck(:id)` in `ServiceCommands#locked_targets` (`app/services/timekeeping/local_owner/service_commands.rb`) and from `LocalEntry.where(...).order(:id).lock(ROW_LOCK).pluck(:id)` in `ReservationOperations#lock_entries` (`app/services/timekeeping/local_owner/reservation_operations.rb`), together: the example's two sessions share only the entry row, one on each path. `LocalOwner#locked_entries`, which has its own run under **Local-owner entry row lock** above, and the adapter's copy in `Invoices::PreparedReservations#lock_entries` were left alone, because neither session calls them.

- `local_owner_service_commands_spec.rb:1102`, "bills nothing for invoice A when successor invoice B commits A's retained entry while mark_billed waits": 1 example, 1 failure, on `expect(blocked_by?(billing_pids.first, commit_pids.first)).to be(true)` with `Expected false to equal true.`.
- `Invoices::OperationLock.acquire!` in the `mark_billed` command lock of `ServiceCommands` got no run. No example in the five files runs two commands on one invoice: this example uses invoices A and B, and the line 1044 example runs `detach_entries`. So no example here waits on that lock.

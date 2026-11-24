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

- `-e 'keeps v3 when a v2 delivery'`: 1 example, 0 failures, on each of 4 runs. It stays listed under **Not yet run** below, with the reason.

**Timekeeping receipt-key lock.** Removed `WriteSteps.lock_key(...)` from `Timekeeping::EntryWriter#lock_receipt_key` in `timekeeping/app/services/timekeeping/entry_writer.rb`. The other `lock_key` callers, in `ServiceCommands` and `ReservationOperations`, were left alone, because entry writes do not reach them.

- `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb`: 10 examples, 3 failures. "answers two identical PATCHes with one key ...", "answers two identical DELETEs with one key ..." and "answers two creates with one key and different bodies ..." each failed with "the second request never waited on the first one's lock".

**Timekeeping outbox lock.** Removed both acquisitions of `pg_advisory_xact_lock(OUTBOX_LOCK_KEY)`: in `Timekeeping::WriteSteps.write_outbox` (`timekeeping/app/services/timekeeping/write_steps.rb`) and in `OutboxSnapshot.lock_for_insert!` (`timekeeping/app/models/outbox_snapshot.rb`).

- `entry_writer_race_spec.rb`: 10 examples, 1 failure. "makes a write to another entry, with another key, wait for the first write's outbox commit" failed with "the second request never waited on the first one's lock".

**Timekeeping admission share lock.** Removed `FOR SHARE` from `Timekeeping::Admission.locked_generation` (`timekeeping/app/models/timekeeping/admission.rb`), which both `EntryWriter` and `ServiceCommands` call. `Admission.locked_state` was left alone, because entry writes do not call it.

- `entry_writer_race_spec.rb`: 10 examples, 2 failures. "makes a fence wait until the write that read the admitted generation commits" failed with "the second request never waited on the first one's lock". "a fence that times out behind an admitted write ..." failed with "expected ActiveRecord::LockWaitTimeout but nothing was raised"; its teardown then hit a deadlock while truncating, which is an after-effect of the unfenced write and not counted.
- "refuses with stale_generation a write that reads the generation after a fence commits" stayed green. The fence commits before the write reads the generation, so nothing waits: it proves the generation check, not the share lock.

**Timekeeping agent lock.** Removed both acquisitions of the agent lock: `ServiceCommands.lock_agent` in `Timekeeping::EntryWriter#names_detached_agent?`, and `WriteSteps.lock_key(request.company_id, command.fetch(:lock), request.target_id)` in `Timekeeping::ServiceCommands#run` (`timekeeping/app/services/timekeeping/service_commands.rb`), whose detach lock is `"agent"`. The receipt-key `lock_key` call just above it was left alone.

- `entry_writer_race_spec.rb -e 'makes a detach wait'`: 1 example, 1 failure, "the detach finished while the create held the agent lock (ServiceCommands.lock_agent in EntryWriter#names_detached_agent?)". Removing only the `lock_agent` call gave the same failure. The example also checks, from `pg_locks` and the `lock_key` parts the detach passed, that the detach waits in `WriteSteps.lock_key(company_id, "agent", agent_id)`.

**Timekeeping detach marker.** Replaced the `ServiceCommands.agent_detached?` call in `Timekeeping::EntryWriter#names_detached_agent?` with `false`. It is the only caller.

- `entry_writer_race_spec.rb`: 10 examples, 2 failures. "refuses a create held before the agent lock once a detach of the agent committed meanwhile" failed on `expect([created.status, JSON.parse(created.body)]).to eq([404, { "reason" => "not_found" }])`, getting `[201, {"agent_id" => 4, ...}]`. "accepts a create built after a committed detach whose agent still exists, and still refuses one built before it" failed on the same expectation for the late create, also getting a 201. Neither example waits on a lock: the detach commits first, so the stored marker is what refuses the create.

**Not yet run with their mechanism removed.** These hits prove waits on other mechanisms. `spec/db/committed_data_mode_spec.rb` tests `blocked_by?` itself. `spec/services/invoices/prepared_reservations_concurrency_spec.rb` and the `local_owner_*` specs depend on the monolith copies of `lock_entries` and the local-owner locks. In `projection_consumer_spec.rb`, "keeps v3 when a v2 delivery that started first writes after v3 has committed" stayed green with both entry `FOR UPDATE`s removed. Its v2 delivery locks entry 91_006 before the row exists, and v3 inserts and commits before v2 writes, so no session waits on any lock. The order comes from `WHERE timesheet_entries.version < EXCLUDED.version` in `upsert_sql`. A lock-wait assertion would fail on the restored tree, so the example was left unchanged until someone decides what it should prove. In `handoff_concurrency_spec.rb`, the billing-refusal example and the example where step 1's fence waits on a Timekeeping entry update depend on the handoff's step-1 fence.

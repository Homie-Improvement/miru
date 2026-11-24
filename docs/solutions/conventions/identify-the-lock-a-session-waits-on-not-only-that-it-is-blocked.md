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
- The same file adds `TIMEKEEPING_WAITERS_SQL`, a recursive query whose comment says the second waiter waits on the first waiter, not on the holder. It adds `ENTRY_LOCK_QUERY` and `section_9_3_timekeeping_waiting_on_entry_lock?` to reject waits from a later statement such as the reservation INSERT.
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
- `spec/models/timekeeping_ownership_concurrency_spec.rb` and `spec/services/timekeeping/gateway_fence_concurrency_spec.rb` stayed green. They prove other locks on the ownership row, not the billing fence's share lock.

**Handoff settling phase.** Removed `settle_integration.settle!(generation: @generation)` from `Runner#settle` in `lib/timekeeping/handoff/runner.rb`.

- `spec/integration/timekeeping/handoff_concurrency_spec.rb`, "makes step 1 of a rollback wait for an invoice save paused after prepare, and settles the save before the freeze": 1 example, 1 failure, "Fork & Leaf Salads: at the freeze the in-flight operation was not settled (The settle step did not finish; resume or abort the handoff)". That example has no `aggregate_failures`, so the first company's failure stopped the loop. A rerun with the company list narrowed to Copper Kettle Bakery, then restored, failed with the same message for "Copper Kettle Bakery". Select this example with `-e`: selecting it by line number picked the neighbouring example.
- No section 9.3 example depends on the billing fence or the settling phase.

**Not yet run with their mechanism removed.** These hits prove waits on other mechanisms. `spec/db/committed_data_mode_spec.rb` tests `blocked_by?` itself. `spec/services/invoices/prepared_reservations_concurrency_spec.rb` and the `local_owner_*` specs depend on the monolith copies of `lock_entries` and the local-owner locks. `gateway_agent_race_spec.rb`, `gateway_spec.rb`, `projection_consumer_spec.rb` and `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb` depend on the Timekeeping write and agent locks and the fence generation. In `handoff_concurrency_spec.rb`, the billing-refusal example and the example where step 1's fence waits on a Timekeeping entry update depend on the handoff's step-1 fence.

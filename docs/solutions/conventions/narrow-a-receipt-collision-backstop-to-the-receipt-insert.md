---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: service_layer
severity: medium
evidence_grounding: anchored
grounding_evidence: "app/services/timekeeping/local_owner.rb in PR #148 defines ReceiptTaken < ActiveRecord::RecordNotUnique, raises it only from store_receipt, and call rescues only ReceiptTaken before re-running attempt; spec/services/timekeeping/local_owner_atomicity_spec.rb proves a checkpoint RecordNotUnique escapes with no rows stored"
audience: both
related_components:
  - database
  - testing_framework
tags:
  - idempotency
  - record-not-unique
  - backstop
  - retry
  - checkpoint
applies_when:
  - A writer retries after a unique-index collision on its idempotency receipt
  - The transaction also calls injected callbacks or does other inserts that can raise RecordNotUnique
---

# Narrow a receipt-collision backstop to the receipt insert, and retry every step

## Context

`Timekeeping::LocalOwner` stores an idempotency receipt last in its transaction. An advisory lock on the receipt key normally stops two writers with the same key from both reaching that insert. If they still collide on the unique index, the writer should replay the receipt the other writer committed. That retry is a backstop.

The obvious version rescues `ActiveRecord::RecordNotUnique` around the whole transaction. The same transaction also calls the `checkpoint:` callback after each step and inserts entries, audits and outbox rows. Any of them can raise `RecordNotUnique`. A broad rescue retries on all of them. When the error was injected by a test checkpoint to prove rollback, the retry succeeds and commits the write the test expected to fail.

## Solution

Tag the one error the backstop is for, and rescue only that tag:

```ruby
class ReceiptTaken < ActiveRecord::RecordNotUnique; end

def call
  attempt
rescue ReceiptTaken
  attempt
end

def store_receipt(outcome)
  Receipt.create!(...)
rescue ActiveRecord::RecordNotUnique => error
  raise ReceiptTaken, error.message
end
```

The retry calls `attempt` again, which runs the whole step list in a fresh savepoint. It does not jump straight to reading the receipt. In this writer the generation check runs before the receipt lookup, so the retry is still fenced: a collision during a handoff answers `stale_generation`, not the stored answer. Retry once only; a second `ReceiptTaken` escapes.

## Why it matters

- A broad rescue hides real uniqueness bugs in other inserts behind a silent retry.
- It breaks failure injection: a checkpoint error meant to prove "nothing is stored" can end in a committed write.
- A shortcut retry that only reads the receipt skips checks the normal path runs first, here the ownership generation fence.

## Evidence

All from PR #148:

- `app/services/timekeeping/local_owner.rb`: `ReceiptTaken` subclasses `ActiveRecord::RecordNotUnique`; `store_receipt` is the only place that raises it; `call` rescues only `ReceiptTaken` and runs `attempt` again, and the comment there says the rerun checks the generation first and then replays the receipt.
- `spec/services/timekeeping/local_owner_atomicity_spec.rb`, "lets a uniqueness error raised by a checkpoint escape instead of retrying the write": a checkpoint raises `ActiveRecord::RecordNotUnique` once at `entry_written`; the call raises it and row counts do not change.
- The same file, "receipt backstop" (`committed_data: true`): a second connection commits a matching receipt at `receipt_checked`; the call answers the stored 201 body and keeps no entry, audit or outbox row.
- The pull request body lists the backstop rerun as a written-rule concern: the generation is checked again before the stored receipt is replayed.

---
module: invoices
date: 2026-10-27
problem_type: design_pattern
component: reservation_adapters
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/invoices/prepared_reservations.rb finish answers outcome(settled_state) when no prepared operation exists; spec/jobs/deliver_invoice_operation_job_spec.rb shows a refused save's abort row delivered with attempts 0
audience: both
related_components:
  - outbox_delivery
  - operation_coordinator
tags:
  - reservations
  - outbox
  - idempotency
  - commit-abort
applies_when:
  - Writing or changing a reservation adapter's commit or abort
  - Porting semantics from the timekeeping fake into an adapter behind the outbox
---

# Answer the settled state when commit or abort finds no operation

## Context

Invoice saves record an intent, then an outbox row of kind `commit` or `abort`. A delivery job later calls the reservation adapter's `commit` or `abort`. `Invoices::OutboxDelivery` reads the answer as the operation's remote state and pairs it with the intent's state through the contract's `save_reconciliation` table (`Invoices::SaveReconciliation`). A commit row is written only beside a `committed` intent and an abort row only beside a `failed` one, so in practice the row is delivered only when the answer is `committed` (for a commit row) or `aborted` (for an abort row). Any other answer keeps the row and counts another attempt.

A refused prepare stores no `invoice_operations` row, yet the coordinator still writes an abort row for it. The spec fake in `spec/support/timekeeping/fake_timekeeping.rb` answers `not_found` when the operation is missing. An adapter that copies that answer leaves the abort row undelivered forever.

## Solution

In the adapter, treat "no stored operation" and "operation already finished" the same way: answer the settled state for the call and write nothing. `Invoices::PreparedReservations` does this in one place, `finish`:

```ruby
operation = find_operation(request).lock.first
next outcome(settled_state) unless operation&.state == PREPARED
```

So `abort` answers `aborted` and `commit` answers `committed` for a missing, committed or aborted operation. Only a still-`prepared` operation runs the block and moves to its terminal state.

## Why it matters

The fake speaks the wire protocol, where `not_found` is a meaningful answer. The adapter speaks the port that the outbox delivery reads, where only the settled state ends retries. Copying the fake looks correct and passes unit tests that check the adapter alone. It fails only when a refused save's abort row sits in the outbox and is retried on every delivery run.

The same rule makes commit and abort idempotent: a redelivered commit, or an abort that arrives after its commit, also settles without changing rows.

## Evidence

- PR #219 adds `app/services/invoices/prepared_reservations.rb`; its `finish` method answers `outcome(settled_state)` whenever the locked operation is absent or not `prepared`.
- `spec/jobs/deliver_invoice_operation_job_spec.rb` in PR #219 delivers a refused save's abort row to `Invoices::PreparedReservations` and expects `delivered_at` present, `attempts` 0, and no `reservations` or `invoice_operations` rows.
- `spec/services/invoices/prepared_reservations_spec.rb` ("operation never stored") expects `abort` to answer `aborted` and `commit` to answer `committed` for an operation that was never stored, writing nothing.
- The PR body lists this as a deliberate departure from the fake: the fake answers not_found, and that answer would leave the outbox row retried forever.

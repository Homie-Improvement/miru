---
module: timekeeping
date: 2026-11-18
problem_type: design_pattern
component: reservation_operations
severity: medium
audience: both
related_components:
  - admission
  - idempotency_receipts
tags:
  - idempotency
  - receipt-replay
  - settle-step
  - fence
  - stale-generation
applies_when:
  - A write path replays stored idempotency receipts and also has a phase that must stop accepting even repeats
  - A RecordNotUnique rescue rebuilds the answer from stored state
---

# Decide fenced eligibility before replaying a stored receipt

## Context

`Timekeeping::ReservationOperations` normally replays a stored answer before it checks the generation. That way a retry of finished work still gets its answer after the generation has moved. The repository already records this receipt-first rule in `docs/solutions/design-patterns/read-the-idempotency-receipt-before-checks-that-can-change.md`.

The settle step breaks that rule on purpose. While fenced, Timekeeping applies only a commit or abort that carries exactly `settling_generation` and names an operation it stored at that generation. After `stop_applying!`, the same commit must be refused as `stale_generation`. If the receipt is read first, a commit applied during settling and re-sent after stop gets its old 200 instead.

## Solution

Split the order by admission state, read once under one lock:

- `run` takes the operation and invoice key locks, then reads `Admission.locked_state` (`generation` and `settling_generation` in one `SELECT ... FOR SHARE`).
- While fenced, `settling_refusal` decides first. Anything other than an eligible commit or abort returns `stale_generation` before `stored_answer` runs.
- While admitted, the receipt-first order is unchanged.
- The `RecordNotUnique` rescue in `call` builds its own answer from stored state. It now calls `settling_refusal(request, Admission.locked_state)` before `stored_answer`, so the backstop cannot replay a receipt that `run` would refuse.

The `FOR SHARE` read also makes `stop_applying!`, `fence!` and `admit!` wait for an in-flight settling commit. A commit that passed the check cannot land after stop has returned.

## Why it matters

Receipt-first is right for a generation that can only move forward. It is wrong for a phase that ends: replaying a receipt after the end tells the caller the phase still holds. When you add a phase like this, look for every place that rebuilds an answer from stored rows. A rescue or backstop path usually has its own copy of the order and is easy to miss.

Keep the exception narrow. `EntryWriter` and `ServiceCommands` still read `Admission.locked_generation` and keep receipt-first replay, and the admitted path keeps it too.

## Evidence

- PR #372 changes `timekeeping/app/services/timekeeping/reservation_operations.rb`: `run` calls `settling_refusal(request, admission)` before `stored_answer`, and the `RecordNotUnique` rescue calls `settling_refusal(request, Admission.locked_state)` first. The header comment's steps 2 and 3 were rewritten to state this order.
- `timekeeping/app/models/timekeeping/admission.rb` adds `locked_state`, which reads both columns `FOR SHARE`.
- `timekeeping/spec/services/timekeeping/reservation_operations_spec.rb` adds "answers stale_generation, not the stored receipt, when a commit re-sent after stop_applying! reaches the unique-violation backstop", and "replays a commit from its receipt after the handoff admits generation 6, keeping the receipt-first order outside a fence".
- `timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb` adds "makes stop_applying! wait for a settling commit parked after its check, then refuses that commit when re-sent".

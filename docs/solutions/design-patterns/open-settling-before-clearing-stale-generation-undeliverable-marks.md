---
module: timekeeping handoff
date: 2026-11-19
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - invoice_operations
  - background_job
tags:
  - handoff
  - settle
  - outbox
  - stale-generation
  - undeliverable
  - generation
applies_when:
  - A handoff step redelivers invoice_operation_outbox_items rows that a stale_generation answer marked undeliverable_at
  - Code calls TimekeepingOwnership.begin_settling! or the Timekeeping settle endpoint and then depends on settling being open
---

# Open settling before clearing stale-generation undeliverable marks

## Context

When an owner answers `stale_generation` to an invoice commit or abort, the outbox row gets an `undeliverable_at` mark. After that, delivery skips the row. A handoff's settle step must resolve these rows. It has to clear the mark and send the row again.

The owner accepts work for the outgoing generation only after it has opened settling for that generation. Before that, a redelivered row gets `stale_generation` again and is marked again. On top of that, `TimekeepingOwnership.begin_settling!` changes nothing outside a handoff or at a generation that is already stopped. It does not raise. So calling it does not prove that settling is open.

## Solution

`OperationsSettle#settle!` follows a fixed order:

1. Ask the owner to open settling at the outgoing generation, which is the raised generation minus one. Read the result back. The monolith port reads `settling_generation` from the ownership row. The Timekeeping port reads `settling` from the settle answer.
2. If settling is not open, raise `OperationsSettle::NotSettling`. Do this before any mark is cleared or any row is delivered.
3. Clear `undeliverable_at` only on undelivered rows of the outgoing generation.
4. Deliver those rows in id order through `DeliverInvoiceOperationJob`, then run intent recovery.

Match rows to a generation through their intent (`invoice_operation_intents.generation`), not through the generation copied into the row's payload. Delivery builds its request from the intent, so the intent's generation is the one the owner checks.

## Why it matters

If the marks are cleared while settling is closed, each row is refused and marked again. It also uses up a delivery attempt. The step looks like it ran, but the operation stays 'prepared'. Raising first keeps the marks as they were, so a later run can still find and resolve those rows. Filtering by the intent's generation keeps rows from older generations marked. The owner would refuse those rows in any case.

## Evidence

- In PR #401, `lib/timekeeping/handoff/operations_settle.rb` defines `NotSettling`. `settle!` raises it unless `@owner.begin_settling(generation: outgoing)` is true, and only then runs `update_all(undeliverable_at: nil)`.
- `MonolithPort#begin_settling` calls `TimekeepingOwnership.begin_settling!` and then reads `settling_generation` back. Its comment says begin_settling! "changes nothing outside a handoff or at a stopped generation".
- `OUTGOING_GENERATION_SQL` joins to `invoice_operation_intents` on `intents.generation`. Its comment says `OutboxDelivery#request_for` uses the intent, not the payload.
- `spec/lib/timekeeping/handoff/operations_settle_spec.rb` covers this. "settle! with no open handoff raises NotSettling and leaves an undeliverable row marked" checks that the row keeps its mark and stays 'prepared'. "settle! keeps the undeliverable mark on a row whose intent belongs to an older generation" checks the generation filter. "a row marked undeliverable by stale_generation is redelivered and resolved..." checks the success path and that a repeated run applies the commit only once.

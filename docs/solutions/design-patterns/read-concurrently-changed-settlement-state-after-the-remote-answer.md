---
module: invoices
date: 2026-11-15
problem_type: design_pattern
component: service_layer
severity: medium
audience: both
related_components:
  - background_job
tags:
  - outbox
  - settlement
  - timekeeping
  - race-condition
  - pure-function
applies_when:
  - An outbox row is settled from a remote answer plus a stored local state
  - Another job can change that local state while the remote call runs
---

# Read settlement state after the remote answer, not when the request is built

## Context

`Invoices::OutboxDelivery` settles a Timekeeping commit or abort row only when the remote state and the stored intent's state agree. It looks the pair up in the contract's `save_reconciliation` table. `RecoverInvoiceOperationIntentsJob` can move a pending intent to `failed` at any moment, including while the abort request is on the wire.

Building the request already loads the intent. Reusing that loaded row for settlement is tempting, and every test that sets the intent before delivery starts would still pass. But that copy reads `pending` when recovery failed the intent mid-call. The row would then stay undelivered and count an attempt for no reason, and wait for the next sweep to send it again.

## Solution

- Keep the settlement rule a pure function of `(kind, outcome, intent_state)` that returns `:delivered`, `:attempt` or `:undeliverable`. It does no database access.
- In the delivery code, run a fresh query for the intent's state after the adapter answers, inside the transaction that holds the row lock. Pass that value into the rule.
- Use one scope helper (`intent_scope`) for both the request lookup and the state read, so both use the same company and invoice filters.

```ruby
adapter, outcome = settle(item)
rule = SETTLEMENT_RULES.fetch(adapter.class, LEGACY_RULE)
# Read after the answer, because recovery can fail a pending intent
# while the request is in flight.
record(item, rule.call(item.kind, outcome, intent_scope(item).pick(:state)))
```

To test it, change the state inside the HTTP call itself, not between deliveries. Wrap the fake client so it updates the intent right after it forwards the abort. Then assert that the row settles.

## Why it matters

The decision depends on facts read at two different times. If the local fact is read too early, the rule judges a pair that never existed together. Putting the read in the shell and the decision in a pure rule makes the timing visible in one place. It also lets the table-driven rule be tested without a database.

## Evidence

- PR #322, `app/services/invoices/outbox_delivery.rb`: `deliver` calls `intent_scope(item).pick(:state)` after `settle` returns, with a comment that says recovery can fail a pending intent while the request is in flight. `RECONCILED_RULE` and `LEGACY_RULE` are lambdas that take the state as an argument.
- `spec/services/invoices/outbox_delivery_spec.rb` in PR #322: the example "settles an abort row against the intent state read after the answer, not the state seen when the request was built" updates the intent to `failed` inside a wrapped http `call` for the `/reservations/abort` path, and expects `delivered_at` to be set with `attempts` at 0.
- The author reported running that example with `deliver` changed to pass the state read before the adapter call: it failed, and it passed again once restored.

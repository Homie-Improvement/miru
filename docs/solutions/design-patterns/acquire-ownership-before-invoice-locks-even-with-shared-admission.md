---
module: Timekeeping billing fence
date: 2026-10-26
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: speculative
audience: both
related_components:
  - InvoicePayment::RazorpayPaymentLinkFulfillment
  - InvoicePayment::RazorpayPaymentLinkWebhookFulfillment
  - Timekeeping::BillingFence
tags:
  - lock-order
  - postgresql
  - handoff
  - payments
applies_when:
  - A caller locks an invoice before invoking fenced settlement
  - A handoff updates the ownership row while payment handlers are active
---
# Acquire ownership before locking the invoice

## Context

Take the ownership lock before the invoice lock, including in browser return handlers. A fence inside settlement is too late if its caller already holds the invoice lock.

The billing fence takes `FOR SHARE` on the ownership row. Payment handlers can hold these shared locks together. A handoff updates that same row and must wait for admitted billing transactions.

Shared locks alone do not establish a safe order. The handoff introduces a competing update between readers. The failure schedule below explains the risk; it is reasoning about the lock order, not a reported three-connection test result.

## Solution

Put `Timekeeping::BillingFence.transaction` outside `invoice.with_lock` in both the browser return and webhook paths. Do not rely only on the fence inside `InvoicePayment::Settle`.

Use three database connections when testing a change to this order:

1. Let the browser return lock the invoice. Pause before it enters settlement.
2. Let the webhook acquire the ownership share lock, then wait for that invoice.
3. Start the handoff update. It waits for the webhook's ownership lock.
4. Resume the browser return. Its late ownership request can now wait behind the queued handoff update.

This ordering forms a cycle: the webhook waits for the browser return, the handoff waits for the webhook, and the return waits for the handoff. Observe database waits before releasing each paused transaction; thread startup alone does not establish this schedule.

Acquiring ownership first removes the return's ability to hold the invoice while waiting for admission. Keep that order at the outer caller, not only in a shared settlement helper.

## Why it matters

A two-handler test without the handoff can miss this failure. The ownership share locks are compatible until a conflicting update enters the schedule.

Moving a lock into a shared helper changes every caller's effective lock order. Check callers that already use `with_lock`, including browser returns as well as webhooks. Otherwise, individually correct transaction blocks can still abort each other during a handoff.

## Evidence

PR #86, head commit `5b757b144b064084341ef0a7543debbe92f7abbd`, establishes the same outer lock order in both Razorpay payment paths:

- `app/services/invoice_payment/razorpay_payment_link_fulfillment.rb` adds `Timekeeping::BillingFence.transaction` outside the browser return's existing `invoice.with_lock` block.
- `app/services/invoice_payment/razorpay_payment_link_webhook_fulfillment.rb` places `invoice.with_lock` inside the same fence in `settle_new_payment`.
- `app/services/invoice_payment/settle.rb` also enters the fence. That inner fence does not replace the outer wrappers.
- `app/services/timekeeping/billing_fence.rb` obtains `TimekeepingOwnership.lock("FOR SHARE")` before yielding to billing work.

These changes establish the corrected acquisition order. They do not supply a three-connection reproduction of the failure schedule above.

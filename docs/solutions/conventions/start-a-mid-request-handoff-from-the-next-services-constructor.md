---
module: spec/requests/api/v1/mobile/collections
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
grounding_evidence: "spec/requests/api/v1/mobile/collections/billing_fence_spec.rb in PR #116 wraps PaymentProviders::RazorpayPaymentLinkService.new with and_wrap_original, snapshots the invoice and sets handoff_step on the first call, then asserts a 503, one keyed invoice, and the snapshot unchanged"
audience: both
related_components:
  - billing_fence
  - idempotency
tags:
  - billing-fence
  - handoff
  - and-wrap-original
  - idempotency-key
  - partial-commit
applies_when:
  - One request commits a transaction and then runs a second fenced step
  - A test must prove what happens when the fence closes between the two steps
  - A same-key retry must finish a half-done request without a duplicate
---

# Start a mid-request handoff from the next service's constructor

## Context

Mobile collection create does two things in order. First it commits the client and invoice in one fenced transaction. Then it builds a Razorpay payment link in a second fenced step. A handoff can start between the two. The issue asked for a test of that window, followed by a retry with the same idempotency key.

The usual setup, `handoff_step` set before the request, does not reach that window. The first transaction refuses, nothing commits, and the test only repeats the existing create-only case.

## Solution

Start the handoff from inside the request, at the first call to the second step's constructor:

```ruby
handoff_started = false
committed_before_handoff = nil
allow(PaymentProviders::RazorpayPaymentLinkService).to receive(:new).and_wrap_original do |original, **kwargs|
  unless handoff_started
    handoff_started = true
    committed_before_handoff = mobile_fence_invoice_snapshot(kwargs.fetch(:invoice))
    TimekeepingOwnership.current.update!(handoff_step: "close_admission")
  end
  original.call(**kwargs)
end
```

Three details make this work:

- `and_wrap_original` keeps the real service. The fence still runs and refuses.
- The `handoff_started` flag fires only once, so the retry after the handoff ends runs normally.
- The snapshot is taken in the hook, before the handoff starts. That is the state the first transaction committed. Assert that it holds data a write would change (no payments, unpaid, positive amount due, no link). After the 503, compare the reloaded invoice with it.

Then assert the outcome. The 503 is not a rollback: exactly one invoice matches the key, and it has no link. Clear the step and retry with the same key. Expect 200, the same row counts, the same invoice id, and one provider call in total. Send the key once more to prove a resend after success changes nothing.

## Why it matters

A test that starts the handoff too early proves the wrong window. It passes even if the partial-commit path is broken. A baseline taken after the refusal is weak too: a payment or balance change made by the refused step becomes the "expected" value for every later check. Taking the snapshot inside the hook pins the baseline to the commit and nothing after it.

This works for any request that commits and then calls a separately built service. Wrap the constructor of the step you want to interrupt.

## Evidence

PR #116, head commit b9bcfcbe87e7efff4b5d9a46985f3d559d706435, file `spec/requests/api/v1/mobile/collections/billing_fence_spec.rb`, in the example "keeps the committed collection when a handoff refuses its payment link and completes the link on a same-key retry without a second collection":

- The hook above wraps `PaymentProviders::RazorpayPaymentLinkService.new`. Its comment says it starts the handoff after the collection's own fenced transaction has committed and before the link service admits its write.
- After the first POST, the spec expects `:service_unavailable`, `keyed_invoices.call.count` equal to 1, nil link fields, and `mobile_fence_invoice_snapshot(committed)` equal to `committed_before_handoff`. The comment there says the 503 is not a rollback.
- After `handoff_step: nil`, two same-key POSTs each return `:ok`, keep `counts.call` equal to `counts_after_refusal`, and leave `create_payment_link` received `.once`.
- In code review round 3, a reviewer found that the first version took its baseline only after the refusal. The author moved the snapshot into the hook.

---
module: spec/requests/api/v1/mobile/collections
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - billing_fence
  - payment_providers
tags:
  - billing-fence
  - handoff
  - request-spec
  - razorpay
  - test-doubles
applies_when:
  - Writing a request spec that proves a route is refused while a timekeeping handoff is in progress
  - A route reaches the billing fence only through a service object
  - A service has a branch that runs outside the fence
---

# Stub only the provider client, and seed the fenced branch, in billing-fence specs

## Context

The billing fence refuses billing writes while `TimekeepingOwnership.current.handoff_step` is set. The refused request gets a 503 with `reason: "ownership_moving"`, and the client can retry later. Some mobile routes never call the fence themselves. `manual_payment` reaches it only through `InvoicePayment::Settle`, and `payment_link` reaches it only through `PaymentProviders::RazorpayPaymentLinkService`.

So a spec can pass and still never reach the fence, in two ways:

- It replaces the whole service with a double. The double answers, and the fence code never runs.
- Its fixture takes a branch of the service that is outside the fence. For `payment_link`, an invoice that already stores a link reuses it outside the fence. During a handoff that branch can answer 200 or 202.

## Solution

Replace only the outermost external client. Let the controller and the service run for real:

```ruby
allow(PaymentProviders::RazorpayClient).to receive(:new).and_return(razorpay_client)
allow(razorpay_client).to receive(:create_payment_link).and_return(
  { "id" => link_id, "short_url" => short_url, "status" => "created" }
)
```

Start from the state that takes the fenced branch, and assert that state first. For `payment_link`, the invoice must have no stored link (`expect(baseline[:link]).to eq([nil, nil, nil])`).

Check the client double too: `expect(razorpay_client).not_to have_received(:create_payment_link)` after the refusal, and `.once` after the handoff ends. The provider call is the one write the database snapshot cannot show.

Name the example after the branch it covers ("refuses a new mobile payment link"), not the whole route. The reuse branch is not refused, so a name like "refuses payment_link" would claim too much.

## Why it matters

If someone moved the provider call or a write outside the fence, a spec that doubles the service would stay green. So would a spec whose invoice already stores a link. The test would look like coverage and protect nothing. Stubbing at the client keeps the fence on the code path the test runs. It still stops any real call to the provider.

## Evidence

PR #116, head commit b9bcfcbe87e7efff4b5d9a46985f3d559d706435, file `spec/requests/api/v1/mobile/collections/billing_fence_spec.rb`:

- The helper `stub_mobile_fence_link_creation` stubs only `PaymentProviders::RazorpayClient.new`. Its comment says only the provider client is replaced, so the real link service and its fence run.
- The `payment_link` examples have a comment that they cover the new-link path only, because an invoice that already stores a link reuses it outside the fence. Each example asserts the seeded link is `[nil, nil, nil]` before the handoff.
- Each refusal asserts `not_to have_received(:create_payment_link)`, and each post-handoff request asserts `have_received(:create_payment_link).once`.

This document is graded speculative. The fence's position inside `RazorpayPaymentLinkService` and `InvoicePayment::Settle` is not in the diff. Neither is the older create spec that doubles the whole service. Those facts come from the comments in the diff and from the plan. To check them, read `process` in `app/services/payment_providers/razorpay_payment_link_service.rb`.

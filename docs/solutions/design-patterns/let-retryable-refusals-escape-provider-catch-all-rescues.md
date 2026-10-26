---
module: Payment webhooks
date: 2026-10-26
problem_type: design_pattern
component: payments
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/invoice_payment/stripe_payment_succeeded.rb, stripe_checkout_fulfillment.rb, stripe_checkout_failed.rb and app/controllers/webhooks/razorpay_controller.rb add rescue Timekeeping::BillingFence::OwnershipMoving with raise ahead of rescue StandardError; app/controllers/webhooks/paypal_controller.rb includes OwnershipMovingResponse because it inherits ActionController::API; spec/services/invoice_payment/stripe_payment_succeeded_fence_spec.rb proves the refusal escapes and a replay records one payment
audience: both
related_components:
  - Timekeeping::BillingFence
  - OwnershipMovingResponse
  - Webhooks::PaypalController
  - Webhooks::RazorpayController
  - InvoicePayment::StripePaymentSucceeded
tags:
  - webhooks
  - rescue-standarderror
  - retryable-error
  - "503"
applies_when:
  - A new retryable exception can be raised inside a webhook or payment-provider path
  - That path has an existing rescue StandardError that logs and returns
  - A controller inherits ActionController::API and does not include ErrorHandler
---
# Let retryable refusals escape provider catch-all rescues

## Context

Payment providers redeliver a webhook only when the response says to retry, such as a 503. During a Timekeeping handoff, the billing fence raises `Timekeeping::BillingFence::OwnershipMoving`, and `ErrorHandler` turns it into a 503 with `Retry-After`.

Many provider paths already end in `rescue StandardError`. Those rescues log the error and return `nil`, `false` or a 500. `OwnershipMoving` is a `StandardError`, so they catch it first. The provider then gets success or a 500, the refused payment is never written, and the event is not redelivered. The customer is charged and the invoice stays unpaid.

The PayPal webhook controller has a second gap. It inherits `ActionController::API` and does not include `ErrorHandler`, so a re-raised refusal there would never reach the shared 503 renderer.

## Solution

- Before each `rescue StandardError` between the fence and the response, add a rescue for the retryable error that re-raises it:

```ruby
rescue Timekeeping::BillingFence::OwnershipMoving
  raise
rescue StandardError => error
  Rails.logger.error error.message
```

- Put the response in its own small concern, `OwnershipMovingResponse`. `ErrorHandler` includes it, and a controller built on `ActionController::API` includes it directly and rescues the error itself.
- Keep signature checks before the fence, so an unsigned caller gets the same 401 during a handoff.
- Make sure the refused transaction commits nothing that the replay depends on. For example, the `Payment.exists?(provider_event_id:)` check must still find nothing, so the redelivered event records the payment exactly once.

## Why it matters

The failure is silent. Unit tests that call the fence pass, and the catch-all rescue logs a line that looks like a normal error. The money is lost only when a real event arrives during a pause.

Whenever you add a new exception that a caller is meant to retry, list every `rescue StandardError` (or bare `rescue`) on the path from the raise to the response. List every controller base class that does not share the global error handler, too.

## Evidence

PR #86, head commit `5b757b144b064084341ef0a7543debbe92f7abbd`:

- `app/services/invoice_payment/stripe_payment_succeeded.rb`, `app/services/invoice_payment/stripe_checkout_fulfillment.rb`, `app/services/invoice_payment/stripe_checkout_failed.rb` and `app/controllers/webhooks/razorpay_controller.rb` each add a re-raising `rescue Timekeeping::BillingFence::OwnershipMoving` ahead of `rescue StandardError`.
- `app/controllers/webhooks/paypal_controller.rb` includes `OwnershipMovingResponse` and renders the refusal before its `StandardError` rescue.
- `app/controllers/concerns/ownership_moving_response.rb` says in a comment that it is kept apart from `ErrorHandler` for controllers built on `ActionController::API`.
- `spec/services/invoice_payment/stripe_payment_succeeded_fence_spec.rb` expects the refusal to escape with no payment, then one payment on replay and none on a second replay.
- `spec/requests/webhooks/billing_fence_spec.rb` expects a signed Razorpay event to get 503, not 500, and a bad signature to still get 401.

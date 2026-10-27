---
module: invoices
date: 2026-10-27
problem_type: design_pattern
component: reservation_boundary
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/invoices/reservation_boundary.rb mark_billed now raises OperationErrors::Refused when outcome.state == 'refused'; spec/mailers/invoice_mailer_spec.rb 'refused billing under the prepared owner' expects status sending, sent_at nil, entry unbilled, no delivery
audience: both
related_components:
  - invoice_mailer
  - prepared_reservations
tags:
  - billing
  - refusal
  - transactions
  - mailer
applies_when:
  - An adapter method gains a refused answer it could not give before
  - A caller ignores the return value of mark_billed or a similar adapter call
---

# Raise a returned billing refusal inside the sender's transaction

## Context

`InvoiceMailer#update_status` records `sent_at`, the sent status and the billed entries in one transaction, before the mail goes out. It called `Invoices::ReservationBoundary.mark_billed` and ignored the result, because the legacy adapter's billing never refused.

The prepared adapter in PR #219 checks each snapshot before publishing it. For a stored entry the consumer would reject (for example `source: "legacy"`), `mark_billed` rolls back its own savepoint and returns `refused`. Returned, not raised. The mailer's transaction then commits the sent status, and the invoice goes out with its work still unbilled, so billing staff see it as available to bill again.

## Solution

Turn the refused answer into the existing refusal error at the boundary, so every caller's transaction rolls back:

```ruby
outcome = ReservationAdapters.for(ownership).mark_billed(request)
raise OperationErrors::Refused.new(outcome) if outcome.state == "refused"

outcome
```

Prepare and settlement already route refused answers to errors; billing now matches them.

## Why it matters

An outcome object is easy to drop. When a port method that used to always succeed starts returning a refusal, every caller that discards the return value silently treats the refusal as success. Check each caller when you add a new answer, and test through the real caller (here the mailer), not only the adapter, because the adapter test passes either way.

## Evidence

- PR #219, `app/services/invoices/reservation_boundary.rb`: `mark_billed` raises `OperationErrors::Refused` on a `refused` outcome; its comment says the caller's transaction rolls back the sent status with it.
- PR #219, `app/mailers/invoice_mailer.rb`: the `update_status` comment now names a refused billing as one of the failures that leaves nothing written.
- `spec/mailers/invoice_mailer_spec.rb` in PR #219 ("refused billing under the prepared owner") drives the real prepared adapter and expects `Invoices::OperationErrors::Refused` with `unpublishable_entry`, invoice status `sending`, `sent_at` nil, the entry still `unbilled`, and no delivered mail. Per the review answer, this example failed with the new raise removed.

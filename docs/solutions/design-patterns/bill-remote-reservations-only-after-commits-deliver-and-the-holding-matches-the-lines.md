---
module: invoices
date: 2026-10-27
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/invoices/reservation_boundary.rb#mark_billed takes OperationLock and raises BillingRetryable while an undelivered commit row exists, and on any non-committed answer; app/services/timekeeping/reservation_client.rb#mark_billed refuses when the holding is missing or differs from request.entries; specs in spec/services/invoices/reservation_boundary_spec.rb and spec/mailers/invoice_mailer_spec.rb.
audience: both
related_components:
  - reservation_boundary
  - timekeeping_reservation_client
  - invoice_mailer
tags:
  - billing
  - mark-billed
  - invoice-send
  - holding
  - outbox
applies_when:
  - Billing invoice entries through a store whose billing call takes no entry list
  - Changing ReservationBoundary.mark_billed or a reservation adapter's mark_billed
---

# Bill remote reservations only after commits deliver and the holding matches the lines

## Context

The legacy and prepared adapters bill the entries the request names. The Timekeeping `mark_billed` route sends no entry list. Timekeeping bills whatever reservations it holds as committed for the invoice. So a 200 answer says nothing about whether the invoice's current lines were billed. Timekeeping can answer `billed: 0` and the old code would mark the invoice sent and mail it.

Three states make the billed set differ from the lines:
- The invoice's commit row is still undelivered, so Timekeeping holds only a provisional reservation.
- A sent invoice removed a line but kept its entry reserved, or gained a line that reserved nothing remotely.
- The invoice has no holding at all, so the monolith does not know what Timekeeping would bill.

## Solution

- In `ReservationBoundary.mark_billed`, take the invoice's operation lock first, so a running save finishes and writes its commit row. Then refuse with `BillingRetryable` while any commit row for the invoice is undelivered.
- Raise on every answer except `committed`: `Refused` for a refusal, `BillingRetryable` for anything else. The sender's transaction then rolls back the sent status and no mail goes out.
- In the remote client, compare the holding's `entry_ids` with the line entries. Refuse, with no request, when they differ or when the holding is missing and the lines name entries. With no holding and no line entries, answer `committed` with `billed: 0` and send nothing.
- Retry the queued send: `BillingFencedMailDeliveryJob` uses `retry_on` for `BillingRetryable`, so a brief outage does not drop the mail.

## Why it matters

Without these checks, a client gets an invoice for work that stays open for billing, and another invoice can still claim it. Do not reject `billed: 0` on its own: it is a valid answer for entries already billed, which is what makes a resend safe.

## Evidence

- PR #241, `app/services/invoices/reservation_boundary.rb`: `mark_billed` calls `OperationLock.acquire!`, checks `InvoiceOperationOutboxItem.exists?(..., kind: "commit", delivered_at: nil)`, and raises `BillingRetryable` unless the outcome is `committed`.
- PR #241, `app/services/timekeeping/reservation_client.rb`: `mark_billed` computes `mismatched_ids` from the holding and `request.entries` and refuses with `BILLING_MISMATCH_REASON`.
- PR #241, `spec/services/invoices/reservation_boundary_spec.rb`: billing is refused with no mark-billed request while the commit row is undelivered, and bills once it is delivered.
- PR #241, `spec/mailers/invoice_mailer_spec.rb`: a 503 on mark-billed leaves the invoice `sending` with no mail; an entry added without a holding is refused.
- PR #241, `app/jobs/billing_fenced_mail_delivery_job.rb` and `spec/jobs/billing_fenced_mail_delivery_job_spec.rb`: the queued send is rescheduled, then bills and mails once.

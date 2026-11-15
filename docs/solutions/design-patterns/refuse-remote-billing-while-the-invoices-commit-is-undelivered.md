---
module: invoices
date: 2026-11-15
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - background_job
  - messaging
tags:
  - timekeeping
  - mark-billed
  - outbox
  - reservations
  - invoice-send
applies_when:
  - A remote service bills only the reservations it holds as committed and answers success for the rest
  - The commit that promotes a reservation is delivered later by an outbox row that can fail and retry
---

# Refuse remote billing while the invoice's commit is undelivered

## Context

When the Timekeeping service owns time entries, an invoice save prepares a reservation in the service. A separate outbox row then commits it. An outbox row is a stored record that a background job delivers and retries. Sending the invoice calls the service's mark-billed route.

This change assumes the following about the real service. It confirms this behaviour only against the fake service in the specs, not against the real one. In `contracts/timekeeping/reservations.yml`, the mark-billed route's request fields carry no entry list. The new comment in `app/services/invoices/reservation_boundary.rb` states that the service bills every entry it holds as committed for the invoice. The comment also states that the service answers success with nothing billed for any other entry, so an entry that is only prepared gets `200` with `billed: 0`.

Suppose a commit answers 503 and is not applied. If the user sends the invoice before the outbox redelivers the commit, the assumed answer is `200 {billed: 0}`. The client maps that to `committed`, the sent status is saved, and the mail goes out. The review of this change also assumed that a later commit redelivery only promotes the reservation and never retries billing. This change does not confirm that against the real service. That assumed behaviour is the risk the guard prevents: the entry could stay unbilled on a sent invoice.

## Solution

Check the cause before the call, not the answer after it. In `Invoices::ReservationBoundary.mark_billed`, under the timekeeping owner:

1. Take the invoice's `OperationLock`, so a save of the same invoice cannot add a new commit row meanwhile.
2. Look for an `InvoiceOperationOutboxItem` with `kind: "commit"` and `delivered_at: nil` for this company and invoice.
3. If one exists, raise `OperationErrors::PrepareRetryable` with reason `"commit_undelivered"` and send no billing request.

The mailer calls `mark_billed` inside the billing transaction, so the raise rolls back `sent_at` and the sent status, and no mail is sent. Once the job delivers the commit, the same send succeeds and the entry is billed.

Keep the answer table strict as well: only `committed` returns, `refused` raises `Refused`, and every other state raises `PrepareRetryable`. But a strict table cannot catch this case, because `billed: 0` is a valid success.

## Why it matters

A success answer with a zero count looks the same whether nothing needed billing or the billing silently missed entries. The remote side cannot tell them apart, so the caller must. The fact that decides it, whether this invoice still has an undelivered commit, lives only in the monolith's outbox.

The same rule applies to any later remote call that acts only on committed state while the commit travels through a retrying outbox. Gate the call on the outbox row, under the lock that stops new rows from appearing.

The local adapters behave differently: they bill the entries on the invoice's lines. The `mark_billed` comment now records an assumed difference, taken from the contract and the fake rather than checked against the real service. The remote route would bill every committed entry for the invoice, including one whose line was removed from a sent invoice.

## Evidence

- PR #318 adds `raise_while_commit_undelivered!` and `COMMIT_UNDELIVERED_REASON = "commit_undelivered"` to `app/services/invoices/reservation_boundary.rb`, and the `MARK_BILLED_ROUTES` table that lets only `committed` return. The same file's new comments state the assumed service behaviour described in Context.
- `spec/mailers/invoice_mailer_timekeeping_spec.rb`, example "refuses to send while the invoice's commit is undelivered, then bills the entry and sends once the commit is redelivered": commit answers 503, the send raises `PrepareRetryable` with `"commit_undelivered"`, `sent_at` stays nil, no mail is delivered, and no mark-billed request reaches the fake. After `DeliverInvoiceOperationJob.perform_now`, the send succeeds and the entry's `bill_status` is `"billed"`.
- In the review of PR #318, the author reported that with the guard disabled, this same example failed at the expected `commit_undelivered` raise.
- `app/services/timekeeping/reservation_client.rb` maps a `200` mark_billed answer with an integer `billed` to `committed`, which is why `billed: 0` passes the answer table.

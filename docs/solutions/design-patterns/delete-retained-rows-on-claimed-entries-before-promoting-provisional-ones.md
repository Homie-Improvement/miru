---
module: invoices
date: 2026-10-27
problem_type: design_pattern
component: reservation_adapters
severity: high
evidence_grounding: anchored
grounding_evidence: "make_desired_set_the_reservation_set in app/services/invoices/prepared_reservations.rb deletes retained committed rows on claimed_ids without filtering by invoice before update_all(state: COMMITTED); spec 'reclaiming a retained entry' expects one active committed row"
audience: both
related_components:
  - reservations
tags:
  - reservations
  - unique-index
  - commit
  - retained
applies_when:
  - Writing a commit step that turns provisional reservation rows committed
  - A table allows one committed and one provisional row per entry
---

# Delete retained rows on claimed entries before promoting provisional ones

## Context

The `reservations` table allows one committed and one provisional row per `(company_id, entry_id)`. Prepare gives an invoice a provisional row for every free entry, and also for a desired entry it holds only as `retained`, so a competing successor cannot take it first. Commit later turns those provisional rows committed.

The issue says commit "drops another invoice's `retained` reservation on the same entry". Taken literally, an invoice that reclaims its own retained entry keeps its old retained committed row. Promoting the new provisional row then makes a second committed row and breaks the unique index. The delivery rolls back, the operation stays `prepared`, and the commit outbox row fails on every retry while later saves of that invoice are refused.

## Solution

In commit, run the writes in this order:

1. Delete committed rows with disposition `retained` on the claimed entries, whichever invoice holds them.
2. Delete the invoice's committed rows for released entries.
3. Promote this operation's provisional rows to committed.
4. Set the operation's disposition on all of the invoice's committed rows.

```ruby
Reservation.where(company_id: operation.company_id, entry_id: claimed_ids, state: COMMITTED,
                  disposition: RETAINED).delete_all
invoice_committed(operation).where(entry_id: released_ids).delete_all
own_provisional(operation).update_all(state: COMMITTED)
invoice_committed(operation).update_all(disposition: operation.disposition)
```

Never delete an active committed row in step 1; prepare already refused such an entry to every other invoice.

## Why it matters

The failure does not show at save time: the invoice save commits, and only the later outbox delivery fails. A stuck `prepared` operation then blocks every later change to that invoice with `unresolved_operation`. Scoping the delete by entry and disposition, not by "other invoice", is what keeps the index valid for both a successor and a reclaim.

## Evidence

- PR #219, `app/services/invoices/prepared_reservations.rb`: `make_desired_set_the_reservation_set` and its comment on the one-committed-per-entry index; `claimed_ids` adds provisional rows for entries this invoice retains.
- `spec/services/invoices/prepared_reservations_spec.rb` in PR #219: "reclaiming a retained entry" and "an invoice that reclaims an entry it only retains commits to one active committed row without a unique violation" expect a single `committed`/`active` row and no operation left `prepared`.
- The PR body records this as a step beyond the written rule: commit also drops the invoice's own retained row on an entry it claims again, so the one-committed-row index holds.

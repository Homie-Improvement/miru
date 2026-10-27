---
module: invoices
date: 2026-10-27
problem_type: design_pattern
component: reservation_adapters
severity: high
evidence_grounding: anchored
grounding_evidence: committed_claim in app/services/invoices/prepared_reservations.rb returns an active row first, then yields to claims.other_active_claim before a retained row; specs 'retained row beside another kept invoice's line' and 'own retained row beside another kept invoice's line' expect on_another_invoice
audience: both
related_components:
  - entry_claims
  - reservation_rules
tags:
  - reservations
  - retained
  - line-claims
  - double-billing
applies_when:
  - Building the committed fact passed to Timekeeping::ReservationRules
  - An owner whose sent-invoice admit writes no reservation row
---

# Rank another kept invoice's line claim above a retained reservation

## Context

A sent invoice that gains a line goes through `admit`, which checks the entry and writes no reservation row. That entry is then claimed only through the line. Separately, a discarded sent invoice keeps its entries as a committed row with disposition `retained`, which any later invoice may take over.

If an entry has both a retained row and another kept invoice's line claim, and the adapter hands the retained row to the rules first, the rules see a claim that yields. A draft then takes the entry, commit deletes the retained row, and two kept invoices bill the same entry. This happened twice during review of PR #219: once for another invoice's retained row, and once for the invoice's own retained row (a restored invoice reclaiming its entries).

## Solution

Build the claim the rules see in this order:

1. An active committed reservation row.
2. Another kept invoice's active claim, through an active holding or a direct or grouped line (`Invoices::EntryClaims#other_active_claim`).
3. A retained row, whichever invoice holds it, this one included.

```ruby
def committed_claim(committed)
  row_claim = committed && { invoice_id: committed.invoice_id, disposition: committed.disposition }
  return row_claim if committed&.disposition == ACTIVE

  yield || row_claim
end
```

Keep the real reservation row in `decision[:committed]` so later steps that read the row still see what is stored.

## Why it matters

A retained row looks like the stronger fact because it is a real reservation, while a line claim is only inferred. But retained means "may be taken", and a live line means "is billed here". Getting the order wrong lets one entry sit on two kept invoices, which the acceptance bar forbids. The prepared adapter puts another kept invoice's active claim, from `EntryClaims#other_active_claim`, above any retained row, including this invoice's own. Any new owner that reads reservation rows must keep that order.

## Evidence

- PR #219, `app/services/invoices/prepared_reservations.rb`: `committed_claim` and `decide`, which passes `claims.other_active_claim(entry_id, request.invoice_id)` as the fallback block.
- PR #219, `app/services/invoices/entry_claims.rb`: adds `other_active_claim` and keeps the legacy priority order in `committed_claim`.
- `spec/services/invoices/prepared_reservations_spec.rb`: "retained row beside another kept invoice's line" and "own retained row beside another kept invoice's line" both expect `refused` with `on_another_invoice` and unchanged reservation rows. Per the review answers, each failed when the old ordering was put back.

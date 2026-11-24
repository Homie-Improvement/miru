---
module: timekeeping
date: 2026-11-23
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - local_owner
  - invoices
tags:
  - tenant-isolation
  - ownership-check
  - invoice-ownership
  - fallback
applies_when:
  - Adding an ownership check to a route that previously stored rows under any id the caller sent
  - An ownership rule falls back to the caller's own stored rows when no authoritative row exists
---

# Fence an own-rows ownership fallback with the authoritative owner check first

## Context

The monolith's local owner of timekeeping (`Timekeeping::LocalOwner`) used to accept any invoice id on prepare. It stored an `invoice_operations` row under the caller's company with whatever id the caller sent. PR #590 makes prepare and mark-billed refuse an invoice the path company does not own, with 404 `not_found`.

The rule needs a fallback for hard-deleted invoices. They have no `invoices` row left, but their reservations still belong to a company. So an id the company's own `invoice_operations` rows hold still counts as owned.

The trap: some of those `invoice_operations` rows were written by the old, unchecked prepare. A row like that names the caller's company and another company's invoice. A plain fallback ("owned if my own operation rows hold this id") treats that row as proof. The foreign id then stays admitted for every new prepare and mark-billed, so the caller's entries can still be locked or billed under another company's invoice. Scoping every read to the caller's company does not help, because the bad row is the caller's own row.

## Solution

Ask the authoritative sources about other owners before you read the fallback. `Timekeeping::LocalOwner::InvoiceOwnership.owned?` decides in this order:

```ruby
def owned?(company_id:, invoice_id:)
  return true if OwnedInvoices.ids(company_id:, invoice_ids: [invoice_id]).include?(invoice_id)
  return false if Invoice.where(id: invoice_id).where.not(company_id:).exists?
  return false if InvoiceOperationIntent.where(invoice_id:).where.not(company_id:).exists?

  ReservationOperations::InvoiceOperation.exists?(company_id:, invoice_id:)
end
```

1. The company's own invoice or intent admits the id (the shared `Timekeeping::OwnedInvoices` rule).
2. Another company's `invoices` row refuses it. Invoice ids are one primary key across companies, so that row proves another owner.
3. Another company's `invoice_operation_intents` row also refuses it. The intent commits before the new invoice row is visible to other connections, so for an in-flight invoice the intent is the only proof of its owner.
4. Only then do the company's own operation rows count. By now that covers the case the fallback exists for: an id with no owner row anywhere.

The check runs in `call`, before any lock or replay, and refuses with the same `not_found` answer as an unknown id. Callers cannot tell "another company has it" from "nobody has it".

## Why it matters

Adding a check does not fix the rows the code wrote before the check existed. Any rule that trusts state the old code wrote must first rule out that state being the bug's own output. Here the cost of getting it wrong is a hole between tenants that the new check seems to close but does not.

When PR #590 merged, the Timekeeping service still used the plain fallback, so the local owner was stricter than the service in this one case. The fix was not to "align" the local owner by copying the service's rule; the service was the one that had to gain the guard. It has since gained it: `Timekeeping::InvoiceOwnership.owned?` reads the reference endpoint's `invoices` and `foreign_invoice_ids` before its own `invoice_operations` rows (see serve-requested-foreign-ids-as-bare-ids-when-a-remote-owner-check-keeps-an-own-row-fallback.md).

Steps 2 and 3 above now live in one shared rule, `Timekeeping::OwnedInvoices.held_by_others`. The local owner calls it in place of the two inline queries shown, and the reference endpoint serves the same rule to the service.

Each guard line needs its own test. In review, someone found that deleting the intent line left every spec green, so the author added a test for it.

## Evidence

- PR #590 adds `app/services/timekeeping/local_owner/invoice_ownership.rb` with the order above. Its header comment explains why another company's invoice or intent row is read before the fallback.
- `spec/services/timekeeping/local_owner_invoice_ownership_spec.rb` holds the cases. The requester's own `invoice_operations` row that names another company's invoice does not admit prepare or mark_billed (404, row counts unchanged). Another company's intent on an id with no invoice row, plus the requester's operation row, gives `owned?` false for the requester and true for the other company.
- `spec/services/timekeeping/local_owner_reservations_spec.rb` (context "more tests 13") shows the fallback still admits an id that only the company's own operation row holds, with no invoice row anywhere.
- The author ran `local_owner_invoice_ownership_spec.rb` with the intent line deleted and got 7 examples, 1 failure. With the line present, the spec passed.
- The PR #590 body records the deviation at that time: the local owner refused an id whose invoice row belongs to another company even when the requester had an old operation row for it, while the service still admitted that case. PR #616 closed that gap in the service.

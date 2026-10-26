---
module: Invoices bulk deletion
date: 2026-10-26
problem_type: convention
component: api_layer
severity: high
evidence_grounding: speculative
grounding_evidence: "app/services/invoices/bulk_deletion_service.rb holds destroy_in_savepoint with Invoice.transaction(requires_new: true) and a comment saying Rails does not roll back a failed destroy's child deletions inside the shared transaction; spec/services/invoices/bulk_deletion_service_spec.rb checks that a paid invoice keeps its line items, taxes and totals in a mixed batch"
audience: both
related_components:
  - Timekeeping::BillingFence
  - Invoice
  - InvoiceLineItem
tags:
  - activerecord
  - savepoint
  - destroy
  - restrict-with-error
  - transactions
applies_when:
  - A loop of destroy calls is moved inside one outer transaction
  - A model destroys dependents before a restrict_with_error association refuses the destroy
---
# Give each destroy its own savepoint inside a shared transaction

## Context

Bulk invoice deletion used to call `invoices.reject(&:destroy)`. Each `destroy` ran in its own transaction. When an invoice had payments, `restrict_with_error` refused the destroy, and Rails rolled back everything that destroy had done.

That rollback mattered. An invoice destroys its line items and taxes before the payment check refuses. Each line-item destroy also recalculates the invoice totals.

The billing fence now wraps the whole batch in one transaction, so a handoff refuses the whole batch at once. Inside that outer transaction, each `destroy` joins it. A failed destroy still returns false, but its rollback no longer undoes the child deletions. They commit with the outer transaction, while the response still reports the invoice as undeletable.

## Solution

Run each destroy in its own savepoint, and roll the savepoint back when the destroy fails:

```ruby
def destroy_in_savepoint(invoice)
  destroyed = false
  Invoice.transaction(requires_new: true) do
    destroyed = invoice.destroy
    raise ActiveRecord::Rollback unless destroyed
  end
  destroyed
end
```

The outer fenced transaction keeps one lock for the whole batch. Each savepoint brings back the per-record rollback the code had before.

To test it, use a mixed batch: one deletable invoice and one invoice with a payment, line items and taxes. Assert that the paid invoice's children and money fields match a baseline taken before the request.

## Why it matters

The change looks harmless. The return value of `destroy` is unchanged, and so is the 422 list. The only sign of the bug is a paid invoice that has lost its line items and totals, which is quiet data corruption on financial records.

The same trap applies to any loop of `save` or `destroy` calls that can fail, once it moves into an outer transaction for locking or atomicity. Look for dependent destroys or callbacks that write before the refusal.

## Evidence

PR #86, head commit `5b757b144b064084341ef0a7543debbe92f7abbd`:

- `app/controllers/api/v1/invoices/bulk_deletion_controller.rb` wraps the batch in `Timekeeping::BillingFence.transaction` and adds `destroy_in_savepoint`. Its comment says the invoice destroys line items and taxes before payments refuse, and that inside the shared transaction Rails does not roll those deletions back by itself.
- `spec/requests/api/v1/invoices/bulk_deletion_spec.rb` adds a mixed-batch example with no handoff. It expects 422 naming only the paid invoice, and it expects the paid invoice's line-item count, tax count, `amount`, `tax` and `outstanding_amount` to equal the baseline.
- That PR also added a duplicate of this check in `bulk_deletion_fence_spec.rb`. The duplicate has since been folded into `spec/requests/api/v1/invoices/bulk_deletion_spec.rb`, whose mixed-batch baseline now also compares `discount`.
- The plan review raised this as a blocker before the savepoint existed.

The rule now lives in `Invoices::BulkDeletionService` (`app/services/invoices/bulk_deletion_service.rb`), which the controller calls. `spec/services/invoices/bulk_deletion_service_spec.rb` holds the mixed-batch baseline check and the handoff refusal, without going through HTTP.

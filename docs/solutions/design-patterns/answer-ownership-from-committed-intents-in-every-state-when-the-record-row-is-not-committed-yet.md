---
module: timekeeping
date: 2026-11-23
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - api_layer
  - testing_framework
tags:
  - ownership
  - reference-endpoint
  - invoice-operation-intents
  - before-committed
  - tenant-isolation
  - fail-closed
applies_when:
  - The monolith calls Timekeeping from inside a transaction, before the record's own row commits
  - Timekeeping asks the monolith's reference endpoint who owns that record
  - Someone adds a state filter to the intent lookup in the reference facts
---

# Answer ownership from committed intents in every state when the record row is not committed yet

## Context

Timekeeping has no invoices table. To refuse another company's invoice id on prepare and mark-billed, it asks the monolith's reference endpoint which requested invoice ids belong to the path company.

The obvious answer is `company.invoices.where(id: ...)`. That answer is wrong for two real cases:

- **A new invoice's first save.** `Invoices::OperationCoordinator` sends prepare from `before_committed!`. The invoice row is not committed yet, so the reference read, on another connection, cannot see it. Only the `invoice_operation_intents` row, which the coordinator commits first on its own connection, exists for other readers.
- **The abort of a rolled-back save.** The abort path replays prepare. By then the invoice row never existed and the intent is in state `failed`. If the reference stops listing the id, Timekeeping answers `not_found`, the abort is refused, and the outbox keeps retrying it.

## Solution

The reference facts list an id when the path company's invoices hold it (discarded ones included) **or** the path company's `invoice_operation_intents` hold it, in any state:

```ruby
invoices = company.invoices.where(id: requested_invoice_ids).pluck(:id)
intents = InvoiceOperationIntent.where(company_id: company.id, invoice_id: requested_invoice_ids)
  .distinct.pluck(:invoice_id)
(invoices + intents).uniq.sort
```

Rules that come with it:

- Both reads filter on the path company. Another company's invoice or intent is left out exactly like an unknown id, so the answer reveals nothing about other tenants.
- Do not add `state: "pending"` to the intent read. The `failed` intent is what lets the abort replay pass.
- The intent is still the monolith's own record, written from the invoice's `company_id`. It is not a second copy of ownership in Timekeeping.
- Prove the ordering with a live spec against a real Timekeeping. A hand-inserted intent row in a request spec does not exercise the uncommitted-row case.

## Why it matters

Without the intent branch, the tenant check refuses every new invoice's first save, which is the most common prepare. Without the `failed` state, a rolled-back save leaves an abort that is never delivered. Both failures are invisible to specs that arrange committed invoices.

One gap remains. The live rollback example prepares successfully before it rolls back, so its abort finds the stored Timekeeping operation and never depends on the failed intent. The failed-intent rule is pinned only by the reference endpoint spec.

## Evidence

- PR #576, `app/services/timekeeping/reference_facts.rb`: `owned_invoice_ids` unions `company.invoices` with `InvoiceOperationIntent` rows for the path company, with no state filter. Its comment says the invoice save commits the intent before it asks Timekeeping to prepare, while the invoice row is not yet visible.
- PR #576, `spec/requests/internal/v1/companies/references_spec.rb`: the invoice-facts example arranges a `pending` and a `failed` intent for company A and expects both listed, and expects a company B intent to read like an unknown id.
- PR #576 review answer: adding `state: "pending"` to the intent query and running that spec gave "18 examples, 1 failure"; the code as left gave "30 examples, 0 failures".
- PR #576, `spec/integration/timekeeping/invoice_first_save_live_spec.rb`: asserts the invoice row is not visible on another connection during prepare (`visible_during_prepare` is `false`) while prepare still answers `prepared`.
- PR #576, `contracts/timekeeping/reference.yml` rule `owned_invoices` and `docs/architecture/timekeeping-soa.md` bullet "Invoice facts" state the same rule.

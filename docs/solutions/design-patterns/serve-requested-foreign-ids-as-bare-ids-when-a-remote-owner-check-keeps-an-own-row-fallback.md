---
module: timekeeping
date: 2026-11-24
problem_type: design_pattern
component: timekeeping
severity: high
audience: both
related_components:
  - reference_endpoint
  - invoice_ownership
tags:
  - tenant-boundary
  - ownership-check
  - reference-contract
  - fail-closed
  - non-disclosure
applies_when:
  - A service without the owning table decides ownership from the monolith's reference endpoint plus its own stored operation rows
  - The owner's contract answers another company's id exactly like an unknown id
  - Porting a local owner's 'another holder refuses first' rule to the remote provider
---

# Serve requested foreign ids as bare ids when a remote owner check keeps an own-row fallback

## Context

The Timekeeping service has no invoices table. It asks the monolith's reference endpoint which requested invoice ids belong to the path company. A hard-deleted invoice is no longer listed there, but its reservations keep their owner. So `Timekeeping::InvoiceOwnership.owned?` also counts an id that the company's own `invoice_operations` rows name.

That fallback is only safe when no other company holds the id. Invoice ids are one primary key across companies. An operation row that an older, unchecked prepare stored under the wrong company would otherwise keep admitting another company's invoice on every prepare and mark-billed.

The monolith's local owner already refused that case, because it can query other companies' invoice and intent rows directly. The service could not copy it. The reference contract said another company's invoice is "left out exactly like an id no invoice has". From the service's side, "another company holds it" and "nobody holds it" (hard-deleted) gave the same answer, and only the second one may fall back to the own row.

## Solution

The check needs three answers per id: mine, another company's, nobody's. Get the third answer from the owner, and give away as little as possible:

1. **One rule in the owner.** `Timekeeping::OwnedInvoices.held_by_others(company_id:, invoice_ids:)` lists the requested ids that another company holds as an invoice (discarded included) or an intent. The local owner and `ReferenceFacts` both call it, so the two providers cannot drift apart.
2. **An additive, bare-id field.** The reference body gains `foreign_invoice_ids`: sorted, once each, only ids the caller asked about, and never the holding company. Only the service-token caller reads it. The service's own callers still get the same `404 not_found` for a foreign id as for an unknown one.
3. **The local owner's order, from one request.** `ReferenceClient#invoice_holders` returns `InvoiceHolders(owned_ids, foreign_ids)` from one reference read, so both lists describe the same moment. Then `owned?` decides:

```ruby
holders = ReferenceClient.configured.invoice_holders(company_id:, invoice_ids: [invoice_id])
return true if holders.owned_ids.include?(invoice_id)
return false if holders.foreign_ids.include?(invoice_id)

InvoiceOperation.exists?(company_id:, invoice_id:)
```

4. **Fail closed on a missing or malformed field.** `invoice_holders` raises `Unavailable` (503 `reference_unavailable`) when `invoices` or `foreign_invoice_ids` is absent. A present field must be a list of Integers. An older monolith without the field must never let the own row decide.
5. **Remove the reader that ignores foreign ids.** `ReferenceClient#owned_invoice_ids` lost its only production caller and was deleted. If it stayed, a later caller could pair it with an own `invoice_operations` row and reopen the cross-company admission.

The cost is real, so decide it on purpose. The service now asks the monolith on every owner-checked prepare and mark-billed, even for an id it already holds a row for. While the monolith is down, those requests get 503 where they used to succeed. Deploy the monolith first and roll the service back first, as for the other additive fields.

## Why it matters

A non-disclosure rule that collapses "foreign" into "unknown" is correct for end callers. But it silently blocks any remote check that must treat those two cases differently. The tempting workarounds are both unsafe:

- Keep reading the own row first. A stale row then admits another company's invoice.
- Fall back to the own row when the new field is missing. A rolling deploy against an older monolith then reopens the same hole.

Narrow the contract instead, to exactly one bit per requested id, and write that narrowing into the contract and the design doc so a reviewer can check it. Keep the bit inside the service-to-service boundary.

## Evidence

- PR #616 (closes issue #592, follow-up to PR #590).
- `timekeeping/app/services/timekeeping/invoice_ownership.rb`: `owned?` now checks `owned_ids`, then `foreign_ids`, and reads `InvoiceOperation.exists?` last. The old version read the own row first and never asked the monolith when that row existed.
- `timekeeping/app/services/timekeeping/reference_client.rb`: adds `InvoiceHolders`, `invoice_holders`, and the `Unavailable` raise for a missing `foreign_invoice_ids`, and removes `owned_invoice_ids`.
- `app/services/timekeeping/owned_invoices.rb` adds `held_by_others`. `app/services/timekeeping/local_owner/invoice_ownership.rb` replaces its two inline `where.not(company_id:)` queries with it. `app/services/timekeeping/reference_facts.rb` serves it as `foreign_invoice_ids`.
- `contracts/timekeeping/reference.yml` adds the `foreign_invoices` rule (bare ids, requested ids only) and the field to `response_fields`. `docs/architecture/timekeeping-soa.md` updates the "Invoice facts" bullet to state the narrower rule.
- `timekeeping/spec/services/timekeeping/invoice_ownership_spec.rb` covers: a foreign invoice or intent with a stale own row refuses; an id nobody holds still counts after one reference request; a missing or malformed `foreign_invoice_ids` raises `Unavailable`.
- `timekeeping/spec/requests/v1/reservations_tenant_invoice_spec.rb` checks that prepare and mark-billed of a foreign id answer `[404, { "reason" => "not_found" }]`, equal to an unknown id, and write nothing.
- `spec/requests/internal/v1/companies/references_spec.rb` checks that foreign and unknown bodies are equal once `foreign_invoice_ids` is set aside, and that the body never names the other company's `company_id`.

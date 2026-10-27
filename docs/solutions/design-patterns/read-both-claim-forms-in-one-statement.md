---
module: invoices
date: 2026-10-27
problem_type: design_pattern
component: invoice_reservations
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/invoices/legacy_reservations.rb EntryClaims::CLAIMS_SQL reads invoice_entry_holdings and the lines of kept invoices in one UNION ALL statement; spec/services/invoices/legacy_reservations_spec.rb 'refuses an entry whose claim moves from a line to a holding while prepare reads the claims' races that move against prepare.
audience: both
related_components:
  - legacy_reservations
  - invoice_entry_holdings
tags:
  - snapshot-consistency
  - concurrency
  - invoice-entry-locking
  - legacy-data
applies_when:
  - A fact can be stored in two forms and some writer moves it between them in one transaction
  - That writer does not take the row lock the reader relies on
---

# Read both claim forms in one statement

## Context

Under the legacy owner, an invoice claims a timesheet entry in one of two ways:

- a row in `invoice_entry_holdings` that lists it, or
- a direct or grouped line of a kept invoice that references it.

The second form exists because invoices saved before holdings existed, and sent invoices that never locked, have no holding and often no lock. So a check that reads only holdings or `locked` lets a second invoice take their entries. Only an entry no kept invoice references counts as a legacy orphan.

When such a sent invoice loses a line, the boundary deletes the line and seeds a holding in one transaction. It does this without the entry row lock. A concurrent `prepare` that read holdings in one query and lines in a second could read "no holding", let that move commit, then read "no line". It would accept an entry the sent invoice still holds.

## Solution

`Invoices::EntryClaims` (app/services/invoices/entry_claims.rb, used by both the legacy and the prepared reservation adapters) reads holdings, whether each holding's invoice is kept, and the direct and grouped line references in one `UNION ALL` statement (`CLAIMS_SQL`). One statement sees one snapshot, so the claim appears in one form or the other.

The same reader serves `commit`'s release check, so a late release never unlocks an entry whose claim was mid-move.

The general rule: if a fact lives in two places and some writer moves it between them without the lock your reader takes, read both places in one statement, or make that writer take the same lock.

## Why it matters

Row locks feel like they make separate reads safe. They do not here, because the move never touches the locked row. The gap is a few milliseconds wide and shows only under a two-connection race, and the result is an entry on two kept invoices.

## Evidence

- PR #201, `app/services/invoices/legacy_reservations.rb`: `EntryClaims::CLAIMS_SQL` and its comment explain why both forms are read together; `committed_claim` gives another kept invoice's line reference priority over a retained holding.
- PR #201, `app/services/invoices/reservation_boundary.rb`: `InvoiceChange#seed_holding` inserts the holding with no entry row lock.
- PR #201, `spec/services/invoices/legacy_reservations_spec.rb`: "refuses an entry whose claim moves from a line to a holding while prepare reads the claims" commits the move after prepare's first holdings read. The fix record in this pull request reports that the same spec failed with "Expected prepared to eq refused" when the read was split back into two statements.
- PR #201, `spec/requests/api/v1/invoices/update_spec.rb`: "refuses a draft update that adds an entry still on a sent invoice whose entries were never locked" covers the line-only claim with no holding and no lock.

---
module: invoices
date: 2026-11-24
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - data_model
tags:
  - reservation-boundary
  - commit-time-check
  - savepoint
  - tenant-isolation
  - timekeeping-ownership
applies_when:
  - A per-record validation is replaced by a check that runs once at commit for the whole transaction
  - Older rows may already hold references the new check would refuse, so only new or changed references may be checked
---

# Check each changed reference row against its first state in the transaction

## Context

While Timekeeping owns time entries, the monolith's `timesheet_entries` table is only a lagging copy, called a projection. Line-item validation can no longer decide whether an entry exists or which company holds it. So PR #603 turns off those validations under that owner. Instead, `Invoices::ReservationBoundary` checks, at commit, every entry reference a save added.

Two things must hold together. Old invoice rows that already name another company's entry must not block later saves. Every new reference to such an entry must still be refused. Deciding "what did this save add" turned out to be the hard part. Each simpler rule tried during review failed:

- **Added ids = ids now minus ids at registration.** A new line naming a foreign id that an older line already names adds nothing to the set, so it passes.
- **Count occurrences per id.** Delete the old foreign line and add a new one with the same id. The count is unchanged, so it passes.
- **Record each changed row and its entry when the callback fires.** A savepoint that is rolled back leaves the record behind. A valid outer edit is then refused.
- **Compare per invoice.** A row moved to another invoice and back inside a rolled-back savepoint looks new on the source invoice.
- **State = entry and invoice only.** A link moved to another line of the same invoice looks unchanged, so its foreign entry escapes the check.

## Solution

Track rows, not ids. Keep each row's first state once for the whole transaction, across all invoices.

- A row's state is `ReferenceState = Data.define(:entry_id, :invoice_id, :line_id)`. All three fields matter. Leaving out `line_id` misses same-invoice link moves.
- Model `before_save` callbacks pass the rows they are about to create, retarget or move to `ReservationBoundary.register(invoice, changed_references:)`. They pass them before the write, so the database still holds the old state.
- `Registry#track` stores `ReferenceState.stored(class_name, id)` only the first time a key is seen (`unless @states_before.key?(key)`). A created row has no id yet, so the record object is kept and treated as having had no prior state.
- At commit, `ChangedReferences.added_by_invoice` re-reads each tracked row. A row counts only if it still exists, names an entry, and its state differs from its first state. A savepoint rollback restores the row or removes it, so a canceled change never counts.
- Every counted entry the invoice cannot hold is refused as `not_found` before anything is sent (`refuse_not_found!(unholdable_entries)`). Entries prepare will not cover go through `admit`.
- Old rows nobody touched are never tracked, so they never fail a save.

## Why it matters

Without this, under the Timekeeping owner a save could attach another company's entry to an invoice. It only needed to reuse, replace or move a reference the invoice already held. The opposite mistake is just as bad: a valid edit returns a 422 because of work a savepoint already canceled. Any future move of a per-row validation to a commit-time check meets the same cases. Use the first state of each row as the baseline, not a set or a count of ids.

## Evidence

- PR #603, `app/services/invoices/reservation_boundary.rb`: `ReferenceState`, `REFERENCE_STATE_COLUMNS`, `ChangedReferences.added_by_invoice`, `Registry#track` and `Registry#added_by_invoice`, and `InvoiceChange#unholdable_entries` / `#refuse_not_found!`.
- PR #603, `app/models/invoice_line_item.rb` (`register_reservation_change_on_save`, which also passes stored links when a line moves invoices) and `app/models/invoice_line_item_time_entry.rb` (`register_reservation_change_on_save`).
- PR #603, `spec/services/invoices/reservation_boundary_spec.rb` has one example for each case above. They cover a new reference to a foreign id an older line names, replacement of an older foreign line, a savepoint-canceled new reference, away-and-back changes, moves to another invoice and back, and a foreign or no-company link moved to another line of the same invoice.

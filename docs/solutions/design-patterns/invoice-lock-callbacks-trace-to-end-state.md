---
module: billing
date: 2026-10-25
problem_type: design_pattern
component: data_model
severity: high
evidence_grounding: speculative
audience: both
related_components:
  - timesheet_entries
  - invoices
  - invoice_line_items
tags:
  - rails-callbacks
  - locked
  - discard
  - dependent-destroy
  - callback-order
applies_when:
  - Describing or changing when a timesheet entry becomes locked or unlocked
  - Writing characterization specs for invoice discard, line-item destroy or bulk invoice delete
  - Reasoning about orphaned locked entries
---

# Invoice lock callbacks: judge an action by its end state, not by the unlock line

## Context

The `locked` boolean on `timesheet_entries` was set and cleared by callbacks in `app/models/invoice.rb` and `app/models/invoice_line_item.rb`. Each unlock callback looked correct on its own.

Those callbacks are gone. `Invoices::ReservationBoundary` (`app/services/invoices/reservation_boundary.rb`) now decides lock changes once per transaction, and `Invoices::LegacyReservations` applies them. A discarded draft now releases its entries, and a draft's removed or destroyed lines release every entry no remaining line references. A sent invoice still keeps its entries when a line is removed, discarded or destroyed. The cases below describe the old callbacks. They still explain the locked entries that no invoice references in existing data, and the rule of tracing to the end state still applies. In two common cases, though, something else triggered by the same action undoes it, and the entry ends up locked. An earlier version of the Timekeeping design document said both cases unlock. That error would have led a team to preserve the wrong behaviour.

## Solution

Before you state what an invoice action does to entry locks, follow every callback it triggers, in order, to the final state.

- **Discarding a draft invoice re-locks its entries.** `after_discard :unlock_timesheet_entries` runs first. Then `after_discard :update_invoice_number` calls `update` to rename the invoice. That save fires `after_save :lock_timesheet_entries, if: :draft?` again, because the invoice is still a draft. The entries finish the discard locked.
- **Destroying a project aggregate line usually leaves its linked entries locked.** `has_many :invoice_line_item_time_entries, dependent: :destroy` is declared before `before_destroy :unlock_timesheet_entries`. Rails runs these in declaration order, so the join rows are gone when the unlock reads `linked_timesheet_entry_ids`. Only the direct `timesheet_entry_id` is unlocked. If `linked_timesheet_entries` was already loaded on that same instance, the ids are still in memory and the unlock works. A freshly loaded line item, which is what the bulk invoice delete destroys, does not have them loaded.
- A bulk hard destroy of a non-draft invoice unlocks nothing, because the line-item unlock runs only for drafts. Together with the aggregate case, this is how entries end up locked with no invoice referencing them.

When you add a callback that must see associated rows during destroy, declare it before the `dependent: :destroy` association, or use `prepend: true`. Pin the outcome with a spec that reloads the record before destroying it.

## Why it matters

Any migration, cleanup job or design that trusts the single unlock line will misclassify entries. Those mistakes show up as entries that employees cannot edit and that no invoice owns. Specs that preload associations can pass while the production path, which loads records fresh, behaves differently.

## Evidence

- PR #6, head commit 032ec20951bffcec52217bbe2ef35dd1b9359e31, revises `docs/architecture/timekeeping-soa.md`. Its section 1.4 and rows L2 and L4 of section 2.3 now describe the draft-discard re-lock and the aggregate-line callback-order case. They replace the earlier statements that both actions unlock.
- The L4 row records that a small ActiveRecord 8.1.3.1 model with the same callback order left the linked entries locked when the line item was freshly loaded, and unlocked them when it was preloaded.
- The section 12.1 characterization list in the same file asks for specs that pin both behaviours.
- The model code is not part of this change. To confirm, read `after_save`, `after_discard` and `update_invoice_number` in `app/models/invoice.rb`, and the association and `before_destroy` order in `app/models/invoice_line_item.rb`.

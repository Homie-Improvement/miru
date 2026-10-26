---
module: invoices
date: 2026-10-26
problem_type: design_pattern
component: data_model
severity: high
evidence_grounding: anchored
grounding_evidence: "app/models/invoice_line_item.rb in PR #83 adds linked_timesheet_entry_ids=, changed_for_autosave?, and a before_save link_pending_linked_timesheet_entries; spec/models/invoice_line_item_spec.rb and spec/requests/api/v1/invoices/update_spec.rb test link-only updates, zero-padded ids, and that valid? writes no join rows"
audience: both
related_components:
  - api_layer
tags:
  - nested-attributes
  - autosave
  - has-many-through
  - ids-writer
  - tenant-scope
  - changed-for-autosave
applies_when:
  - Overriding a has_many or has_many-through `*_ids=` writer so ids resolve within a scope, such as the parent's company
  - The parent saves the child through accepts_nested_attributes_for
---

# Defer a scoped ids writer, and mark it changed for autosave

## Context

Rails gives every `has_many` association an `*_ids=` writer. It looks the ids up in the whole table and raises `ActiveRecord::RecordNotFound` for a missing id. In a multi-tenant app that has two problems. First, it finds another tenant's rows. Second, a missing id gives a 404 while a foreign id gives a validation error, so the caller can tell whether the id exists elsewhere.

The fix is to replace the writer with one that only stores the ids, and to resolve them later within the scope. With nested attributes the scope (here `invoice.company_id`) is often not set yet when the writer runs. But a writer that only stores ids changes no column. That breaks three Rails assumptions.

## Solution

In `InvoiceLineItem`, PR #83 does four things together:

1. **The writer only records and casts.** `linked_timesheet_entry_ids=` drops blanks and casts each id with `TimesheetEntry.type_for_attribute(:id).cast(id)`. The id column's cast reads `"010"` as 10, as the built-in writer did. An earlier version used `Integer(...)`, which reads Ruby number literals and can name a different row.
2. **Pending ids count as a change.** `changed_for_autosave?` returns `super || pending_linked_timesheet_entry_ids?`. Nested autosave validates and saves only children that report a change. Without this, a PATCH that changes only an existing line's links skips the line. A replace or clear is dropped, and a foreign id returns 200.
3. **Validation stays read-only.** The validator checks only the pending ids against `TimesheetEntry.where(company_id: invoice.company_id)`. Assigning the association on a saved record writes join rows at once, so the assignment waits for `before_save`.
4. **The save re-resolves and aborts.** `link_pending_linked_timesheet_entries` looks the ids up again. If any id no longer resolves, it adds `:not_found` and calls `throw :abort`, so the old links are never kept silently.

When ids are pending, the validator checks only them, not the current links. A replacement must be able to remove a link that has become invalid.

## Why it matters

Each missing piece fails quietly. Model specs that call `valid?` on a new record pass without the autosave override. Only a nested update of an existing child, with all other attributes unchanged, shows the bug, and then it shows as a success response. Anyone who copies this pattern for another association needs all four pieces.

## Evidence

- PR #83, head commit 3ea539140f8796b0479c88fa54bdb643a60e93d4, `app/models/invoice_line_item.rb`: `linked_timesheet_entry_ids=`, `changed_for_autosave?`, `before_save :link_pending_linked_timesheet_entries`, and `linked_timesheet_entries_found_in_invoice_company`.
- `spec/models/invoice_line_item_spec.rb`: "counts a persisted line with only pending linked ids as changed for autosave", "writes pending linked ids of a saved line only on save, never on validation", "reads zero-padded linked ids as decimal, the way the id column casts them", "clears and replaces links even when a current link no longer belongs to the invoice's company", and "refuses the save when a pending linked entry stops resolving after validation".
- `spec/requests/api/v1/invoices/update_spec.rb`: "applies a link-only replacement that adds no join rows when repeated, then a link-only clear", with every other attribute sent unchanged.

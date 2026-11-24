---
module: invoices
date: 2026-11-24
problem_type: convention
component: api_layer
severity: medium
audience: both
related_components:
  - data_model
tags:
  - has-many-through
  - projection-lag
  - jbuilder
  - relay-paused
applies_when:
  - A join table may name rows that a lagging projection table does not hold yet
  - A response lists ids that a client edits and sends back
---

# List link ids from the link rows, not a through reader over a lagging projection

## Context

Under the Timekeeping owner, PR #603 lets an invoice line link to an entry that the paused relay has not copied into `timesheet_entries` yet. The link row in `invoice_line_item_time_entries` stores the id. However, `linked_timesheet_entry_ids` comes from the `has_many :through` association, and its SQL inner-joins `timesheet_entries`. So the response leaves out that link, and nothing raises an error.

The invoice editor sends back the linked ids it was shown. An edit made while the relay is paused would therefore drop the link and release its reservation.

## Solution

Read the ids from the join rows themselves. PR #603 adds `InvoiceLineItem#linked_entry_ids_on_rows` (`invoice_line_item_time_entries.map(&:timesheet_entry_id)`). Both invoice views now call it instead of `linked_timesheet_entry_ids`.

The same applies to any reader that a client trusts as the full list: if the target table can lag, do not join it.

## Why it matters

A through reader over a projection answers "which linked rows are projected", not "which rows are linked". The difference only shows while the projection lags, which is exactly when the data is most fragile. The loss is silent. It also passes through a normal edit and save, so no single request looks wrong.

## Evidence

- PR #603, `app/models/invoice_line_item.rb` adds `linked_entry_ids_on_rows`, with a comment explaining that the through reader joins `timesheet_entries`.
- PR #603, `app/views/api/v1/invoices/_invoice.json.jbuilder` and `app/views/internal_api/v1/partial/_invoice_line_item.json.jbuilder` switch `json.linked_timesheet_entry_ids` to `linked_entry_ids_on_rows`.
- PR #603, `spec/requests/api/v1/invoices/timekeeping_entry_check_spec.rb` (the unprojected linked entry group) asserts that the create and show responses list `linkedTimesheetEntryIds` as `[[entry_id]]` for an entry the projection lacks.
- In the review history, printing the association scope's SQL showed `INNER JOIN` between `timesheet_entries` and `invoice_line_item_time_entries`.

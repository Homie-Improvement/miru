---
module: billing
date: 2026-10-25
problem_type: convention
component: data_model
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - invoices
  - invoice_line_items
  - invoice_taxes
  - pdf_generation
tags:
  - audited
  - financial-parity
  - rounding
  - pdf
  - migration
applies_when:
  - Proving that a migration, backfill or data move did not change invoice money
  - Comparing invoice totals shown to customers with stored values
---

# Prove invoice money parity by snapshot, not by the audit log

## Context

You may need to show that a data move left invoice money untouched, for example a migration, a rollback or a reconciliation job. The obvious tool is the audit history, because `Invoice` is marked `audited`. That history does not cover enough of the money to prove anything. The stored `amount` is also not the figure the customer sees on the PDF.

## Solution

Take a snapshot of the stored values before and after the operation, and require them to be identical:

- invoice `amount`, `tax`, `discount` and `outstanding_amount`;
- every line item's `rate` and `quantity`;
- every `invoice_taxes` row;
- the totals of the rendered PDF.

Compare the PDF totals separately. `PdfGeneration::InvoiceService` recomputes the subtotal from `total_cost_of_all_line_items`, rounded to 3 places. It prints the total as `subtotal + tax - discount`, unrounded. The stored `amount` is a float subtotal rounded to 2 places, minus discount, plus tax, rounded to 2. The two can differ, so checking `amount` alone does not prove the printed figure is unchanged.

## Why it matters

The `audited` declaration on `Invoice` omits `discount`, `tax` and `outstanding_amount`. `InvoiceLineItem` and `InvoiceTax` are not audited at all. A check that reads the audit log would report "no change" while a rate, quantity or tax row had been rewritten. Customers see the PDF, so the PDF has to be part of the comparison.

## Evidence

- PR #6, head commit 032ec20951bffcec52217bbe2ef35dd1b9359e31, revises `docs/architecture/timekeeping-soa.md`. Section 1.6 replaces the earlier claim that invoice money is audited with the list of what `audited` covers and omits. It also describes how the PDF recomputes its totals.
- Row M4 in section 2.4, the money row of the reconciliation table in section 10.4, and acceptance criterion AC2 in section 13 of the same file all require the snapshot comparison instead of the audit log.
- The model and service code is not part of this change. To confirm, read the `audited` options in `app/models/invoice.rb` and the totals in `app/services/pdf_generation/invoice_totals.rb`, which `PdfGeneration::InvoiceService` uses to build the PDF and exposes through `PdfGeneration::InvoiceService.printed_totals`.

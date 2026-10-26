---
module: Timekeeping::FinancialSnapshot
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: In spec/services/timekeeping/financial_snapshot_spec.rb at cdb3f51, the mutation table lists, for each update_column change, the full set of stored and printed keys it moves (for example tax moves [:invoice, i, :tax], [:pdf_total, i, :invoice_tax] and [:pdf_total, i, :total]) and then checks the first key's old and new value separately; app/services/pdf_generation/invoice_totals.rb reads tax, discount, amount, amount_due, amount_paid and the line items when the totals are read.
audience: both
related_components:
  - pdf_generation
  - invoices
tags:
  - financial-snapshot
  - invoice-money
  - pdf-totals
  - mutation-tests
  - update-column
applies_when:
  - A snapshot or comparison captures stored columns together with values computed from those columns
  - A test changes one column with update_column and checks what the comparison reports
---

# Assert the exact set of differences when a snapshot holds derived values

## Context

`Timekeeping::FinancialSnapshot.take` captures two kinds of value for each invoice. It reads stored columns (`amount`, `tax`, `discount`, `outstanding_amount`, line item `rate` and `quantity`, invoice tax rows). It also reads the totals the invoice PDF prints, through `PdfGeneration::InvoiceService.printed_totals`. Those printed totals are computed from the same columns each time the snapshot is taken.

The first test plan said each column change should produce exactly one difference. That cannot hold. `update_column` skips model callbacks, so no other stored column moves. But the printed totals still read the changed column. Changing `tax` changes the stored tax, the printed `invoice_tax` string, and the printed `total` (`subtotal + tax - discount`).

## Solution

For each mutation, write down the full set of keys it must move, and assert that set exactly with `match_array`. Then check the stored field's own difference on its own: its old value, new value and `company_id`.

The mapping used here, for invoice `i`, line item `l` and invoice tax `t`:

- `amount`: stored amount and printed `invoice_amount`
- `tax`: stored tax, printed `invoice_tax`, printed `total`
- `discount`: stored discount, printed `invoice_discount`, printed `total`
- `outstanding_amount`: stored value only (the PDF does not print it)
- line item `rate` or `quantity`: the stored value, printed `sub_total`, printed `total`
- invoice tax `amount`: stored amount and printed `pdf_invoice_tax` amount
- invoice tax `value`: stored value only
- `amount_paid` or `amount_due`: printed value only, because neither is a stored value the snapshot compares

Move each value by enough (10 here) that the formatted string changes too. A tiny change can round away in the printed string, and the expected set would then be wrong.

## Why it matters

A count-only or one-difference check fails in two ways. It rejects a correct snapshot, which pushes the author to drop the derived values. Or, if relaxed to "at least one difference", it passes even when the snapshot forgot the stored field, because a printed total still moved. The exact set catches both. The separate check on the stored field makes sure a derived difference cannot stand in for it.

The last two rows matter for a different reason. A change that moves only a printed value proves the printed total is compared apart from the stored `amount`, which is why the PDF totals belong in the snapshot at all.

## Evidence

- PR #78, head commit cdb3f51909aee8c5c0fc5e1c073aa9a0cb3be4a0.
- `spec/services/timekeeping/financial_snapshot_spec.rb`: the example "reports exactly the expected keys for one change of each kind on seeded invoice money" holds the mutation table above. It asserts each set with `match_array` and checks the first key's `old_value` and `new_value` apart. A comment there notes that `update_column` skips callbacks but the printed totals still read the changed column.
- `app/services/pdf_generation/invoice_totals.rb`: `formatted_invoice_amounts` reads `amount`, `tax`, `amount_due`, `amount_paid` and `discount`; `total` reads `tax` and `discount`; `subtotal` reads the line items. These reads are why one column moves several snapshot keys.
- `app/services/timekeeping/financial_snapshot.rb`: `INVOICE_FIELDS` holds only `amount tax discount outstanding_amount`, so `amount_paid` and `amount_due` changes appear only as `:pdf_total` differences.

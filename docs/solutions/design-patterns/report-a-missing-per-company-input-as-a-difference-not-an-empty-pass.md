---
module: Timekeeping::Handoff::Reconciliation
date: 2026-10-26
problem_type: design_pattern
component: timekeeping_handoff
severity: high
evidence_grounding: anchored
grounding_evidence: lib/timekeeping/handoff/reconciliation.rb run builds company_ids from every input including money maps, corrections and expected_reservations; check_money emits :snapshot_missing per missing side; check_inputs! raises ArgumentError for a snapshot or expected reservation filed under another company; reconciliation_spec.rb covers both cases
audience: both
related_components:
  - timekeeping_handoff
  - financial_snapshot
tags:
  - reconciliation
  - multi-tenant
  - company-id
  - missing-input
  - handoff
applies_when:
  - A check produces one verdict per company from inputs keyed by company_id
  - A comparison of two inputs returns an empty list when both are absent
  - Callers pass maps of company_id to rows or snapshots
---

# Report a missing per-company input as a difference, not an empty pass

## Context

Handoff reconciliation gives each company its own verdict. The money check compares a before and an after financial snapshot per company. The first design checked only companies that appeared in one of the two money maps. A company with entries but no snapshot on either side got a money check with nothing to compare. The empty list of differences then certified money that nobody had checked.

A related hole: classification rows in `expected_reservations` were read by the map key they were filed under. The row's own `company_id` was never read. A row for company 202 filed under 101 produced a clean classification check for 101.

## Solution

- Take the company set from **every** input. `run` in `lib/timekeeping/handoff/reconciliation.rb` collects `company_id` from source and checkpoint rows, projection rows and both intent sets, plus the keys of both money maps, the listed corrections and the expected reservations. Every company gets every check.
- Make absence a difference. `check_money` emits one `:snapshot_missing` difference for each missing side before it calls `FinancialSnapshot.compare`, so the company aborts.
- Refuse misfiled input before any check runs. `check_inputs!` raises `ArgumentError` when a money snapshot's `:company_id` differs from its map key, or when an expected reservation row has a `company_id` that differs from its map key. A row with no `company_id` is taken as belonging to the company it is filed under.
- A row that no single company claims (a projection row with a nil `company_id` whose id several companies share) goes to `Result#unassigned`. Any row there aborts the run. The row is never dropped and never filed under a guessed company.

## Why it matters

In a per-company verdict, "no differences" and "no data" look the same unless the code tells them apart. Missing data must fail loudly, because the operator reads a clean section as proof. Misfiled input is worse than missing input: it can pass one company on another company's data, and nothing in the output shows it. When you add a new per-company input, add it to the company set, give it a missing-side difference, and check that its rows match the key they are filed under.

## Evidence

PR #92, head commit 23fd205128e594c79c537a6f660c31934c92f3e2.

- `lib/timekeeping/handoff/reconciliation.rb`: `run` builds `company_ids` from all row inputs and adds the keys of `money_before`, `money_after`, `listed_corrections` and `expected_reservations`. `check_money` returns `:snapshot_missing` differences when a side is nil. `check_inputs!` raises for a snapshot or an expected reservation filed under another company. `place_projection` sends unclaimed nil-company rows to `unassigned`, and `Result#abort?` aborts on any of them.
- `spec/lib/timekeeping/handoff/reconciliation_spec.rb`, "fails the money check of a company with entries but no financial snapshot on either side", "leaves a projection row with no company whose id two companies share unassigned and aborts" and "refuses a classification row filed under a company other than its own".

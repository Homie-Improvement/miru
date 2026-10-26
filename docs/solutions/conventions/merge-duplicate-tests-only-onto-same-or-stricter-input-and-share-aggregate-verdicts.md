---
module: timekeeping_handoff
date: 2026-10-26
problem_type: convention
component: timekeeping_handoff
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/lib/timekeeping/handoff/reconciliation_spec.rb in PR #182: expect_recon_checks_abort_in_a gains expect(result.unassigned).to eq([]) and expect(result).to be_abort. Separate examples are kept for an entries correction beside an unlisted note change and for company 404 that appears only in the money snapshots."
audience: both
related_components:
  - testing_framework
tags:
  - rspec
  - test-consolidation
  - coverage
  - reconciliation
applies_when:
  - Merging or deduplicating spec files or examples that assert overlapping rules
  - Moving examples onto a shared assertion helper
---

# Merge duplicate tests only onto the same or a stricter input, and put whole-result verdicts in the shared helper

## Context

PR #182 merged five reconciliation spec files into one file built on shared helpers. Many examples looked like copies of each other. Several of them still guarded a separate code path or a separate input shape. Dropping them as duplicates removed coverage, and every remaining test still passed.

Three kinds of loss showed up:

- **Same rule, different check.** A correction test that took its correction from a `:projection` difference does not cover a correction on the `:entries` check. `Correction#explains?` compares `check`, `row_key` and `field`, so a too-broad match limited to `:entries` would go unnoticed.
- **Same rule, different input shape.** A company that appears only in the money snapshots, with no rows at all, reaches reconciliation by a different path than a company with rows. Each money example that remained had rows for every company.
- **Aggregate verdict swapped for a local one.** Merged examples checked `result.companies.fetch(101)` aborts but no longer checked `result` aborts. Then nothing covered how `Result#abort?` combines company verdicts.

## Solution

- Before you delete an example as a duplicate, name the example that will own its rule. Confirm that the owner uses the same or a stricter input on the same code path: the same check, the same input shape, and a second unlisted change where the original had one. If no owner qualifies, keep the case as its own named example.
- When examples share an assertion helper, put the whole-result checks in the helper. Then every example that uses it keeps them. `expect_recon_checks_abort_in_a` now asserts `result.unassigned` is empty and `result` aborts, beside the per-company checks.
- To prove an owner really guards the rule, break the code on purpose. Then check that the owning example fails, and restore the code.

## Why it matters

Merging tests is reported as "only a reorganisation", so reviewers expect behaviour coverage to stay the same. A dropped case fails nothing. The loss shows up only when the code it guarded regresses. Two examples with the same title can test different code, so judge each one by its input and code path, not by its name.

## Evidence

PR #182, `spec/lib/timekeeping/handoff/reconciliation_spec.rb`:

- `expect_recon_checks_abort_in_a` gains `expect(result.unassigned).to eq([])` and `expect(result).to be_abort`.
- "does not let an entries correction for one field excuse a changed note on the same entry" lists `Correction.new(check: :entries, row_key: [1], field: "locked")`. It asserts that the note difference stays unlisted. The test sits beside "lets a listed correction pass only for its own company, row and field", which takes its correction from a projection difference.
- "reports a changed discount for a company that appears only in the financial snapshots" adds company 404 only to `money_before` and `money_after`. It asserts the company's money difference, its abort, and the `Timekeeping::FinancialSnapshotChanged` event under 404.
- `docs/solutions/design-patterns/match-listed-corrections-on-the-exact-difference-and-never-on-duplicates.md` now cites the entries correction example as evidence.

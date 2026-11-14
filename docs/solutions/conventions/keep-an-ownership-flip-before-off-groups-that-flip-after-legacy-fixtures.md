---
module: invoices
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/services/invoices/prepared_reservations_spec.rb in PR #239 wraps only some groups in context 'with the prepared store owning timekeeping' with before { prepare_local_ownership! }, while the line-claim groups stay outside and call TimekeepingOwnership.current.update! inside the example after building timesheet entries and invoice lines"
audience: both
related_components:
  - timekeeping_ownership
tags:
  - rspec
  - spec-consolidation
  - before-hooks
  - timekeeping-ownership
applies_when:
  - Merging several top-level RSpec.describe blocks into one
  - Some groups set a global state in a before and others set it inline after building fixtures
---

# Keep an ownership-flip `before` off groups that flip after legacy fixtures

## Context

`TimekeepingOwnership.current` decides which store owns timekeeping writes. Many prepared-reservation specs flip it to the prepared store (`owner: "monolith", monolith_store: "prepared"`) in a `before`. The line-claim specs work differently. They first build `timesheet_entry` and `invoice_line_item` rows under the legacy owner. Then they flip ownership inside the example. That order is the scenario under test: an entry claimed only through a sent invoice's line.

When many copies of the same `before` sit in one file, the easy fix is one file-wide `before`. That runs the flip before every example body, so it also runs before the line-claim fixtures.

## Solution

Put the shared `before { prepare_local_ownership! }` on a nested `context` that wraps only the groups that already flipped ownership up front. Leave the groups that flip inline outside that context, and keep their inline `TimekeepingOwnership.current.update!` call after their fixtures. Groups that never set ownership (here, `admit`) also stay outside. Say this in a comment above the context, so the next person does not hoist it.

Before you hoist any `before` that changes global state, check each group for an inline call that sets the same state. If a group has one, its fixtures depend on the old state.

## Why it matters

The moved examples keep passing either way, so the suite gives no warning. With the flip first, the line-claim fixtures are built under the prepared store instead of the legacy owner. The examples then no longer prove that a line written under the legacy owner still blocks a second invoice after the handoff. You lose coverage of a cross-owner path, and the suite stays green.

## Evidence

- PR #239, `spec/services/invoices/prepared_reservations_spec.rb`: the single `RSpec.describe Invoices::PreparedReservations` holds `context "with the prepared store owning timekeeping"` with `before { prepare_local_ownership! }`. The comment above that context says the line-claim groups set ownership "only after building legacy-owner fixtures; admit needs none."
- In the same file, the groups `entry claimed only through a sent invoice's line`, `entries claimed only through a sent invoice's lines`, `retained row beside another kept invoice's line` and `own retained row beside another kept invoice's line` sit outside that context. Each calls `TimekeepingOwnership.current.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)` after creating its `timesheet_entry` and `invoice_line_item` rows.
- PR #239, `spec/services/invoices/prepared_reservations_spec_layout_spec.rb`: the example that checks ownership asserts that no `before` block calls `TimekeepingOwnership.current.update!` and that exactly one `before` calls `prepare_local_ownership!`.

---
module: Timekeeping contracts
date: 2026-10-25
problem_type: design_pattern
component: testing_framework
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #27 spec/support/timekeeping/fake_timekeeping.rb: reserve_provisionally stores operation_key built from company, actor and operation_id, and own_provisional selects by that key; spec/contracts/timekeeping/idempotency_examples.rb checks that one service's abort leaves another service's same-id reservation alone."
audience: both
related_components:
  - TimekeepingContract::FakeTimekeeping
  - reservations
tags:
  - timekeeping
  - idempotency
  - operation-id
  - actor-isolation
applies_when:
  - An operation id is scoped by company and actor, and the operation creates or owns other rows
  - Implementing prepare, commit or abort for the Timekeeping reservations contract
---

# Carry the scoped operation identity into every row the operation owns

## Context

The Timekeeping contract says an operation id from another company or another actor never matches. Two services in one company may both use the same `operation_id`.

The fake first scoped only the operation lookup by company, actor and operation id. The provisional reservation rows that prepare wrote still matched on company and `operation_id`. As a result, when service A aborted, service B's reservations with the same id were dropped too, and a commit by either service committed both entry sets. The actor-isolation examples stopped after prepare, so every group still passed.

## Solution

Build one key from company, actor and operation id. Use it for the operation record, and store it on every row the operation creates.

In the fake, `operation_key` comes from the `operation_key` policy (`[company_id, actor, operation_id]`). `reserve_provisionally` writes it onto each reservation. `own_provisional` selects reservations by `reservation[:operation_key] == operation[:key]`, so commit and abort touch only their own rows.

To test this, go past the lookup. Let two services prepare different entries under the same id. Then let one service abort, and check that the other service's reservation survives and can still commit.

## Why it matters

Scoping the lookup key looks complete, and lookup-level examples pass. The leak sits in the step that finishes the operation, where the code selects child rows. A real provider that copies the lookup fix but keeps raw `operation_id` on its reservation table would release or commit another service's reservations. That damages invoice state without any error.

## Evidence

PR #27, head commit `e485f7ac3333e22641e2f9b2da540f6276e55698`:

- `spec/support/timekeeping/fake_timekeeping.rb`: `prepare` builds `operation_key` and passes it to `reserve_provisionally`, which stores it on each reservation. `own_provisional` filters on it. A comment there says another actor's operation with the same id never commits or aborts these rows.
- `spec/contracts/timekeeping/idempotency_examples.rb`: the example "keeps another service's reservations when one service ends an operation with the same id" aborts as one service and commits as the other.
- `spec/contracts/timekeeping/mutation_spec.rb`: the row "looks up operations without the actor" drops the actor from `operation_key` and must fail the idempotency group.
- `contracts/timekeeping/reservations.yml`: `rules.abort_scope` says abort drops only this operation's provisional reservations.

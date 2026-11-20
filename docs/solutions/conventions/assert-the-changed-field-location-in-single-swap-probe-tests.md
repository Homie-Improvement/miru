---
module: timekeeping tenant guard
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/timekeeping
tags:
  - probe
  - single-swap
  - request-diff
  - tenant-guard
applies_when:
  - A spec proves a negative-case request differs from a valid one in exactly one field
  - A case table claims which identifier kinds each case covers
---

# Assert the changed field location in single-swap probe tests

## Context

In the Timekeeping tenant guard, a probe is the requester's valid request with one identifier swapped for another company's. The meta spec flattens both requests into `[location, text]` leaves. It first checked that exactly one leaf changed and that the new text was the owner's value of the kind the case covers.

Those two checks do not say which field changed. A reviewer mutated the table: the commit invoice probe was relabelled to also cover `operation_id` and `idempotency_key`, and the real operation probe was removed. The spec still passed. Putting `op-owner-0001` into `invoice_id` would also pass. The table would then report full coverage while no case sends a foreign operation id.

## Solution

Keep a table of where each route carries each identifier kind, and require every kind a probe covers to sit at the one location that changed. In `spec/meta/timekeeping_tenant_guard_surfaces_spec.rb` this is `guard_cases_swap_locations`, for example `%i[reservations commit operation_id] => [:body, "operation_id"]` and `%i[entry_api update entry_id] => [:path, 5]`. The example asserts:

```ruby
expected_locations = kase.covers.map { |kind| guard_cases_swap_locations.fetch([kase.contract, kase.route, kind]) }
expect(expected_locations.uniq).to eq([changed.keys.first]), label
```

A case that covers two kinds through one field (reservations commit, where the body `operation_id` is also the idempotency key) passes, because both kinds map to the same location.

## Why it matters

The case table feeds a completeness check. If a case can claim a kind it never sends, the check counts that kind as covered, and the live guard tests a different refusal than the one the case names. A check that fails early, such as an invoice lookup, can then hide a broken operation-id check.

## Evidence

- PR #452, `spec/meta/timekeeping_tenant_guard_surfaces_spec.rb`: `guard_cases_swap_locations` and the R5 probe-diff example that compares `expected_locations.uniq` with the single changed leaf.
- The PR #452 code review recorded the mutation (commit invoice probe relabelled, operation probe removed). The author's recorded run with that mutation gave 28 examples, 1 failure, in the R5 probe-diff example; the unmutated table gave 0 failures.
- `spec/support/timekeeping/tenant_guard_cases.rb` in PR #452 holds the `ROWS` table whose `covers` values this check constrains.

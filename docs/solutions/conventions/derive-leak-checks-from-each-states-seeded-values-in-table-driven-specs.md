---
module: spec/requests/api/v1/users
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: low
evidence_grounding: anchored
grounding_evidence: "In spec/requests/api/v1/users/destroy_spec.rb, PR #163 adds `refusal_body_states`, where each state has its own `columns` and `hidden_values`. Each example first asserts `TimekeepingOwnership.current.attributes.symbolize_keys` includes `state[:columns]`, and `refusal_body_states.each` defines one `it` per label."
audience: both
related_components:
  - api_layer
tags:
  - rspec
  - parameterized-specs
  - leak-tests
  - negative-assertions
applies_when:
  - Merging several 'the response must not contain X' examples into one table-driven group
  - Writing absence assertions for a refusal body across several seeded states
---

# Derive leak checks from each state's seeded values in table-driven specs

## Context

Some request specs prove that a refusal reply leaks no stored data. They seed a row, send the request, and assert that the body does not include the seeded values. In `spec/requests/api/v1/users/destroy_spec.rb`, two such examples covered two states of the shared timekeeping ownership row. They were merged into one table.

A check like `expect(response.body).not_to include(value)` has a trap. It passes whenever the value is missing, and that includes a state that never wrote the value. If you merge states and give them one shared list of forbidden strings, some checks in some states test nothing. The spec stays green, and nothing tells you the coverage got weaker.

## Solution

Give each row of the table three things:

1. **The columns it seeds.** In this file that is `columns:`.
2. **The values from those columns that must not appear.** In this file that is `hidden_values:`. Add any value that applies to every state, such as `company.name`, when you run the checks.
3. **A check that the seed took effect, made before the request.** This spec asserts `TimekeepingOwnership.current.attributes.symbolize_keys` includes `state[:columns]`. Without this check, a seed that silently did nothing would make every absence check pass.

Leave out values too short to search for. The table's comment says generation `2` gets no substring check, because a single digit shows up in almost any body.

Loop over the table when the examples are defined, not inside one example:

```ruby
refusal_body_states.each do |label, state|
  it "holds only the fixed handoff message and no ownership values (#{label})" do
    # seed, assert baseline, request, assert body
  end
end
```

An `each` loop inside one `it` stops at the first failed expectation. Then the other states never run, and the output does not say which state failed. One `it` per row runs every state and puts the label in the failure.

## Why it matters

Negative assertions are the weakest kind of test. Their whole value depends on the forbidden value being present in the data at the time of the request. When states are merged for tidiness, that link is the first thing to break. The cost of keeping it is one list per row and one baseline assertion.

To confirm the group still catches a leak, put one seeded value into the reply for a moment and check that every row fails. Then remove the change.

## Evidence

- PR #163 changes `spec/requests/api/v1/users/destroy_spec.rb`. It replaces the two inline refusal-body examples with a `context "when a handoff has begun, the refusal body"` that holds a `refusal_body_states` hash. The "owned by Timekeeping" state hides `"handoff-operator-7731@example.com"`, `"4217"` and `"timekeeping\""`. The "prepared monolith store" state hides `"operator-jane"` and `"prepared"`.
- The same diff adds a comment saying generation 2 gets no substring check, because a single digit is not a useful leak test. Each example checks `(state[:hidden_values] + [company.name])`.
- Each example asserts that the ownership row holds `state[:columns]` before it calls `delete_user(target_user)`.
- The PR's test plan reports a temporary controller edit that added `changed_by` to the refusal body. With that edit, `-e "refusal body"` ran 2 examples with 2 failures. The edit was then reverted.

---
module: spec/services
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - factories
tags:
  - rspec
  - faker
  - flaky-test
  - change-matcher
  - factory-defaults
applies_when:
  - A spec uses `change { ... }.to(literal)` on an attribute the factory fills with Faker
  - An example passes alone but fails under one CI random seed
---

# Pin the starting value when a spec expects a change to a literal

## Context

This repo prefers Faker values in factories (see AGENTS.md). That is fine until a spec checks that an update *changes* an attribute to a fixed value, for example `expect { ... }.to change { user.last_name }.to("Smith")`.

The `change` matcher in RSpec fails when the value before and after is the same. If the factory's Faker draw is already "Smith", the update is a no-op and the example fails with "expected result to have changed to \"Smith\", but did not change".

The Faker draw follows the suite's random seed. So the example passes when you run it alone, and fails every time under the one seed that produces the collision. Issue #203 reported exactly this for `Team::UpdateService`: red in 3 of 3 CI re-runs with the same seed, green when run alone.

## Solution

When a spec expects a change to a literal, set the starting value in the fixture to a different literal. Do not let Faker choose it.

```ruby
# Fixed names that differ from user_params, so the "changes to" expectations
# hold whatever names Faker would have generated.
let(:user) { create(:user, first_name: "John", last_name: "Doe", current_workspace_id: company.id) }
```

This falls under the AGENTS.md exception "unless a spec needs a fixed literal". A change-to-literal assertion needs one on the *before* side too, not only the *after* side.

When you review a spec, check each `change { ... }.to(X)` and ask where the starting value comes from. If it comes from a factory's Faker call that can return `X`, pin it.

## Why it matters

The failure depends on the seed, so it looks like random flakiness. People re-run CI or blame the base branch, and the defect stays. Common target values such as "Smith" or "John" are also common Faker outputs, so the collision is more frequent than it seems. Pinning the start costs one line and makes the example pass under any seed.

## Evidence

- PR #205 changes only `spec/services/team/update_service_spec.rb`. It replaces `create(:user, current_workspace_id: company.id)` with a user created with `first_name: "John", last_name: "Doe"`, and adds a comment that the names must differ from `user_params`. No assertion changes.
- Issue #203 (closed by PR #205) records the failure text from `spec/services/team/update_service_spec.rb:23` and that the example passes when run alone. The diagnosis that Faker produced "Smith" under the CI seed comes from that issue's reasoning; this change does not reproduce the seed itself.

---
module: api_v1_users
date: 2026-10-26
problem_type: convention
component: api_layer
severity: medium
evidence_grounding: anchored
grounding_evidence: "In PR #149, app/controllers/api/v1/users_controller.rb adds the handoff check in destroy after the existing early return; spec/requests/api/v1/users/destroy_spec.rb pins an unchanged 403 for a non-super-admin, an unchanged status for a missing user id, and the sole-owner message winning during a handoff."
audience: both
related_components:
  - timekeeping_ownership
  - authorization
tags:
  - refusal-order
  - information-leak
  - authorization
  - timekeeping-handoff
applies_when:
  - Adding a refusal to a controller action based on state shared by every tenant or company
  - The action already has a lookup, an authorize call or an earlier business refusal
---

# Put a global-state refusal after authorization and existing refusals

## Context

The `TimekeepingOwnership` row is one global row for every company. PR #149 makes `Api::V1::UsersController#destroy` refuse the super-admin hard delete with a 422 once a handoff has begun.

If that check ran first, the 422 would reach callers who should see something else:

- A caller who is not a super admin would get 422 instead of 403. That tells them about the global handoff state, which they have no right to see.
- Probing a missing user id would answer differently before and after a handoff, which also exposes the state.
- A sole owner would get the generic handoff message, which hides the more useful sole-owner message.

## Solution

Place the new refusal after `User.find`, after `authorize`, and after the existing sole-owner early return. Each caller then gets the same answer as before the change, unless they are allowed to delete and nothing else would stop them.

Keep the refusal body to the fixed locale message `user.super_admin_delete.handoff_begun`. Do not include ownership columns such as `changed_by`, which names a person, or company names.

Pin the order with request specs, not only the refusal itself:

- A non-super-admin during a handoff still gets 403, with no handoff message and no audit row.
- A missing user id gives the same status before and after a handoff begins, and never 422.
- A sole owner during a handoff still gets the `sole_owner` message.
- The refusal body has only an `errors` key and none of the ownership values.

## Why it matters

A guard on global state is easy to add at the top of an action, and the happy-path tests still pass. The leak only shows up in the tests for callers who should be refused for another reason. Without order tests, a later refactor can move the check up and nobody notices.

## Evidence

- PR #149 changes `app/controllers/api/v1/users_controller.rb` so that the `TimekeepingOwnership.unless_handoff_begun` block and the 422 render come after the existing early return in `destroy`.
- `spec/requests/api/v1/users/destroy_spec.rb` adds the "refusal order during a handoff" group, which checks the 403 and the sole-owner message. The "handoff refusal for unknown users" group compares the status for a missing id before and after `handoff_step` is set. The "handoff refusal body" group checks that the body omits `changed_by`, the generation and the company name.
- `config/locales/en.yml` adds the fixed `handoff_begun` message.

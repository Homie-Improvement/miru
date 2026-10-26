---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "In PR #151, spec/services/timekeeping/reference_facts_spec.rb sets up owner-first and admin-first users in separate companies, with comments saying Rolify keeps one roles row per name and company; app/services/timekeeping/reference_facts.rb picks roles ordered by roles.id"
audience: both
related_components:
  - reference_facts
  - user_token
tags:
  - rolify
  - roles
  - fixtures
  - ordering
applies_when:
  - Writing a spec where the result depends on the roles.id order of a user's roles
  - Testing that the older of owner and admin wins
---

# Build each owner/admin role order in its own company

## Context

`Timekeeping::ReferenceFacts` serves a user's oldest owner or admin role in a company. It finds this by ordering the user's roles by `roles.id`. To test this, a spec needs one user who got owner before admin and another who got admin before owner.

Rolify does not create a roles row per user. It keeps one row per role name and resource, shared by every user who holds it. The first `add_role(:owner, company)` creates the owner row. Later holders join that same row. So inside one company, owner and admin have one fixed `roles.id` order for everyone. Two users in one company cannot hold them in opposite orders, whatever order the spec calls `add_role` in.

## Solution

When a spec needs both orders, give each order its own company:

```ruby
owner_first_company = create(:company)
admin_first_company = create(:company)
owner_first.add_role(:owner, owner_first_company)
owner_first.add_role(:admin, owner_first_company)
admin_first.add_role(:admin, admin_first_company)
admin_first.add_role(:owner, admin_first_company)
```

Add a short comment saying why the companies are separate, so nobody merges them later.

The same holds for any rule that reads the role order, not only owner and admin. Employee-before-admin works in a shared company only while no earlier fixture created the admin row there first.

## Why it matters

A spec that puts both orders in one company looks correct, but one of its two examples tests a state that cannot exist. It can then pass or fail for the wrong reason. A broken "oldest wins" rule would slip through. In this change, two examples first written this way had to be split into separate companies, with the expected roles unchanged.

## Evidence

- PR #151, `spec/services/timekeeping/reference_facts_spec.rb`: the "privileged-first users' roles" and "order between owner and admin" groups build the admin-first user in its own company. Their comments say Rolify shares one roles row per name and company among its holders.
- PR #151, `app/services/timekeeping/reference_facts.rb`: `held_role_names_by_user_id` queries `Role.where(resource: company)` ordered by `roles.id`, and `role_from` takes the first name in `PRIVILEGED_ROLES`.
- PR #151 description: one test file changed because two examples gave two users owner and admin in opposite orders in one company, which cannot hold under Rolify.

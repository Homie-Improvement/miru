---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/services/timekeeping/user_token_spec.rb, group 'write role agrees with reference facts': each row checks claims.role against row[:role] and served_role against row[:role]. The group's comment says the token reads its role from ReferenceFacts, so a mistake both sides share would otherwise still agree."
audience: both
related_components:
  - Timekeeping::UserToken
  - Timekeeping::ReferenceFacts
  - User.primary_roles_for
tags:
  - rspec
  - agreement-tests
  - tokens
  - roles
applies_when:
  - Testing that two outputs agree, such as a signed token claim and an API response
  - One output is computed from the other, or both come from the same source
---

# Assert literals, not only agreement, when one side derives from the other

## Context

The timekeeping write token and the reference endpoint must give a user the same role in a company. A spec that only checks `token role == served role` looks like it guards that rule. But the token reads its role from `ReferenceFacts`. If the role rule breaks, both sides return the same wrong value, and the agreement check still passes.

## Solution

Give every agreement case its expected values as literals, and assert each side against those literals. PR #174's agreement table does this for every row:

```ruby
expect([claims.user_id, claims.company_id, claims.role, claims.purpose, claims.primary_role])
  .to eq([member.id, scoped_company.id, row[:role], "write", primary_role])
expect(served_role).to eq(row[:role])
expect(User.primary_roles_for(scoped_company, [member.id])).to eq(member.id => primary_role)
```

This checks agreement indirectly, because both sides must equal the same literal. It also checks that the shared value is right. `primary_role` defaults to `"employee"` in each row and is overridden only where it differs, as in the "a manager only" row.

## Why it matters

An agreement-only test would catch drift between the two sides. It cannot catch a wrong rule that both sides share, and in this code a shared wrong rule is the more likely failure. The spec's code alone does not show that the token takes its role from `ReferenceFacts`, so PR #174 says so in a comment above the table; keep that comment so a later author does not reduce the checks to plain agreement.

## Evidence

- PR #174, `spec/services/timekeeping/user_token_spec.rb`: the group "write role agrees with reference facts" has a comment saying each row asserts the expected role as a literal as well as the agreement, "because the token reads its role from ReferenceFacts and a shared mistake would otherwise still agree."
- The same PR deletes the group "roles agreeing with the write token" from `spec/services/timekeeping/reference_facts_spec.rb`. That group compared the signed roles with the served roles through `expect(signed).to eq(served.slice(...))`, so its agreement check moves into the literal-asserting table.

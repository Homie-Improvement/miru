---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: In spec/services/timekeeping/user_token_spec.rb the table gains rows 'a global admin with no role in the company' and 'another company's admin with no role in the company' next to the employee-plus-outside-role rows. In spec/services/timekeeping/reference_facts_spec.rb the table gains 'an employee who later holds owner and then admin', which sits apart from served_member(:owner, :admin).
audience: both
related_components:
  - Timekeeping::ReferenceFacts
  - Timekeeping::UserToken
tags:
  - rspec
  - table-driven-specs
  - test-consolidation
  - roles
  - coverage
applies_when:
  - Merging several overlapping example groups into one row-per-case table
  - A shared row helper such as scoped_member or served_member adds baseline roles or records to every row
---

# Diff each removed example's setup against its table row when merging specs

## Context

This rule applies when you merge duplicated spec groups into one table with one row per case. A tidy-up like this should change no outcome. Each row usually builds its user through one helper, for example `scoped_member(*roles)` or `served_member(*roles)`. Writing every row through the same helper makes the rows look alike. That sameness can quietly erase the one setup detail that made an old example a separate case.

PR #174 hit this twice, both times in role-selection specs:

- The removed group "roles agreeing with the write token" built a global admin and another company's admin with **no role in the company**. That setup forced the role lookup to fall back to `employee` while an outside admin role existed. The new rows built both users with `:employee` first. A bug that reads global or foreign roles only when the user has no role in the company would then raise the signed role, which crosses a privilege boundary, and every row would still pass.
- The removed group "order between owner and admin" built `:employee, :owner, :admin` and expected `owner`. The new row used `served_member(:owner, :admin)`. In that row the oldest role and the oldest privileged role are both `owner`, so the row no longer checks that the lookup skips the older `employee` role.

## Solution

Before you delete an old example, put its setup next to the new row that claims to replace it. Check every role, every company and every employment record, and check their order. If the two setups differ, keep both variants as separately named rows. Do not edit the existing row to match, because that drops the case the row covers now.

PR #174 added these rows instead of changing existing ones:

```ruby
{ case: "a global admin with no role in the company", role: "employee",
  member: -> { scoped_member.tap { |member| member.add_role(:admin) } } },
{ case: "another company's admin with no role in the company", role: "employee",
  member: -> { elsewhere_member(elsewhere_role: :admin) } }
```

```ruby
{ case: "an employee who later holds owner and then admin", role: "owner",
  member: -> { served_member(:employee, :owner, :admin) } }
```

The two kinds of row stay side by side. `served_member(:owner, :admin)` and `served_member(:employee, :owner, :admin)` are both kept because each one covers a case the other does not.

## Why it matters

A merge like this passes on unchanged code by design, so a green run tells you nothing about lost coverage. The only check that works is to compare the old setup with the new one. In role code, the cases that disappear are often the fallback paths, and those are where privilege escalation hides.

## Evidence

- PR #174 merges four write-role groups in `spec/services/timekeeping/user_token_spec.rb` and six role groups in `spec/services/timekeeping/reference_facts_spec.rb` into one table per file.
- In `spec/services/timekeeping/user_token_spec.rb`, the rows "a global admin" and "another company's admin" give the user `:employee` in the company. The two rows ending "with no role in the company" were added to bring back the no-local-role setup that the deleted reference group used. The comment above them gives the reason: "These two hold no role in the company, so the role falls back to the default while a global or foreign admin role exists."
- In `spec/services/timekeeping/reference_facts_spec.rb`, the row "an employee who later holds owner and then admin" brings back the `:employee, :owner, :admin` setup from the deleted "order between owner and admin" group. The row "a user who holds owner and then admin" stays too.

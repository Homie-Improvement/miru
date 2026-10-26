---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: spec/services/timekeeping/reference_facts_spec.rb keeps the example 'serves each user in one batch their own role and lists no role holder without employment' next to the row table. It builds an employee-first admin, an employee-first owner, a colleague and an outsider admin, then calls ReferenceFacts once.
audience: both
related_components:
  - Timekeeping::ReferenceFacts
tags:
  - rspec
  - table-driven-specs
  - batch-lookup
  - per-user-isolation
applies_when:
  - The code under test computes values for many records in one call, for example by grouping roles by user id
  - Turning multi-user examples into one row per user
---

# Keep a mixed-value batch example beside per-row tables

## Context

`Timekeeping::ReferenceFacts.call` serves a role for every employed user of a company in one call. It groups the roles it holds by user id. A table with one row per case builds one user and makes one call for that row. Bugs that mix values up between users in the same call therefore never show up in the table. Two kinds of bug fall in this gap:

- The code picks one privileged role for the whole company and gives it to every privileged holder.
- The code credits one user's admin role to a colleague.

When PR #174 first planned its merge, it moved the employee-first admin and the employee-first owner into separate rows. The batch example it kept then held only one privileged user. A per-company mix-up would have passed every test.

## Solution

Keep one example next to the table that puts several users into **one** call. Their expected values must differ from each other. In PR #174 that example holds:

- an employee-first admin, expected `admin`
- an employee-first owner, expected `owner`
- a colleague who is admin only in another company, expected `employee`
- an outsider who is admin here with no employment, expected to be left out

```ruby
expect(served_users).to contain_exactly(
  { id: admin.id, role: "admin" },
  { id: owner.id, role: "owner" },
  { id: colleague.id, role: "employee" }
)
```

Each of these users holds at most one privileged role, so one company is safe here. Separate companies are only needed when rows build owner and admin in opposite orders.

The same idea makes "left out" rows in the table meaningful. Each row also builds a roleless bystander and expects it in the served list. A row that expects its user to be absent still fails if the call returns no users at all.

## Why it matters

Rows that each build one user are easier to read, and they make the batch example look redundant. It is not redundant. It is the only test that runs the grouping code with more than one distinct answer.

## Evidence

- PR #174, `spec/services/timekeeping/reference_facts_spec.rb`: the example "serves each user in one batch their own role and lists no role holder without employment" sits next to the role table. Its comment reads: "Holders of different privileged roles share one call, so a lookup that mixes up roles between users in the batch fails here."
- In the same file, the table's examples call `served_member` for a bystander and expect `{ id: bystander.id, role: "employee" }` in every row. The comment above the table explains that this keeps rows that expect a user to be left out from passing on an empty list.

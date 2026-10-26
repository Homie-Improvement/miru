---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/contracts/timekeeping/entry_api_examples.rb arranges foreign_agent with company: other_company, user: owner, commented 'only its company is wrong', in PR #117 at f7eb21efa496a2ad86b248fa7a852a074cc80f62"
audience: both
related_components:
  - contract_examples
  - multi_tenancy
tags:
  - tenant-isolation
  - not-found-parity
  - test-fixtures
  - contract-tests
applies_when:
  - A rule refuses for several reasons and gives the same answer for each
  - A test proves another company's record is answered exactly like a missing id
---

# Arrange a foreign-tenant fixture that differs only in its tenant

## Context

The entry API's agent rule refuses three cases with the same 404 `not_found`: an agent that does not exist, another company's agent, and a colleague's agent in the same company. Giving every case one answer is deliberate: a different answer would let a caller probe which ids exist in other companies.

That sameness hides which condition fired. A test fixture first used an agent of another company owned by another user. That agent was wrong on both company and user. The user check alone refuses it, so the test still passes if the company check is deleted.

## Solution

Arrange the foreign record so the tenant is the only thing wrong with it. Here the foreign agent belongs to the other company but to the entry's own user:

```ruby
# The agent belongs to the entry's own user, so only its company is wrong.
foreign_agent = timekeeping_arrange.agent(company: other_company, user: owner)
```

Keep a separate example for each other reason, such as a colleague's agent in the same company, so each condition has a fixture that only it can refuse. Then compare the foreign answer to the missing-id answer, status and body together.

## Why it matters

Tenant checks are the ones whose loss leaks data between companies. When all refusals look the same from outside, only the fixture decides which check a test covers. A reviewer should ask of each refusal example: if I remove the rule this test is named for, does another rule still refuse this input?

## Evidence

PR #117, head commit f7eb21efa496a2ad86b248fa7a852a074cc80f62:

- `spec/contracts/timekeeping/entry_api_examples.rb`: the example "answers another company's agent exactly as an agent that does not exist, and creates nothing" arranges `timekeeping_arrange.agent(company: other_company, user: owner)` and creates the entry as `owner`. A separate example, "refuses a create with a colleague's agent", covers the same-company, other-user case.
- `contracts/timekeeping/entry_api.yml`: the new `agent_owner` rule says an unknown agent, another company's agent, or a colleague's agent all answer `not_found`, exactly as a missing id does.
- `spec/contracts/timekeeping/mutation_spec.rb`: adds the row "accepts any agent on an entry", which breaks the fake's `agent_owner` policy and expects the shared entry API examples to fail.

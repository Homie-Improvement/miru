---
module: timesheet entry gateway
date: 2026-11-17
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - idempotency receipts
  - timekeeping fake
tags:
  - idempotency-key
  - replay
  - multi-tenant
  - request-spec
applies_when:
  - A spec proves a reused Idempotency-Key is not replayed across a company or other scope boundary
  - The second request must name scope-owned records, so its body cannot match the first request's body
---

# Assert a new scoped write, not only "no replay", in cross-scope idempotency specs

## Context

An idempotency store keeps the answer to each request under a key. A retry with the same key gets the stored answer back instead of writing twice. In this repository, the stored answers are meant to be keyed by company as well as by user, operation and key. A spec that proves this sends the same key from a second company and checks that the second request is not served the first company's answer.

The second request usually cannot copy the first request's body. A project belongs to one company, and naming another company's project is refused before anything is forwarded. So the second request names its own company's project, and its body differs from the first.

If the store ignored the company, that body difference changes what goes wrong. The store would not replay the first entry. It would see a known key with a different body and refuse the request as a reused key. A spec that only checks "the response is not the first entry" can pass while that refusal happens.

## Solution

Write the assertion so that it fails in both ways a store that ignores the company can go wrong:

- Assert that the second response is successful. This rules out the reused-key refusal.
- Assert that the new entry id differs from the first. This rules out a replay.
- Read the stored record and assert its scope columns: `company_id`, `user_id` and `project_id` all belong to the second company.
- Assert that the first stored record is unchanged.
- Assert that both forwarded requests carried the same key, which must be present. A key that was never sent would make the test prove nothing.

State both ways the store can go wrong in a comment beside the assertions. A later reader then knows why a plain "not equal" check would not be enough.

## Why it matters

If the assertion covers only one way of going wrong, the test is weaker than it looks. When company scoping breaks, the store refuses the request instead of replaying. The narrow check does not see that refusal as a replay, so the test keeps passing. Asserting a successful new write under the second company catches both cases with one set of checks.

## Evidence

- PR #349 adds the example "writes a separate entry when one user employed in two companies resends a create with the same Idempotency-Key in the other company" to `spec/requests/api/v1/timesheet_entries/gateway_spec.rb`.
- In that example, a comment says that a replay would answer with the first company's entry, and that a store which ignored the company would refuse the reused key. Either way, the request would not write its own entry.
- The example asserts `expect(response).to be_successful` and `expect(second_id).not_to eq(first_id)`. It checks the stored entry's `company_id`, `user_id` and `project_id` against `other_company.id`, `admin.id` and `other_project.id`.
- It also asserts `expect(fake.stored_entry(first_id)).to eq(first_entry)` and checks `client_key_forwarded_keys("POST")`: two forwarded keys, one unique value.
- In the same file, a second comment says each request names its own company's project, because naming the other company's project is refused before anything is forwarded.
- Verification step to run: change the test fake's stored-answer key so it drops the company. The PR description says that with this change, the new example failed at the second request's success check.

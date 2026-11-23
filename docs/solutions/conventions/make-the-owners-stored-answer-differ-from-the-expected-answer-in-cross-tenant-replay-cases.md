---
module: timekeeping tenant guard
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - timekeeping
  - idempotency
tags:
  - tenant-isolation
  - idempotency-receipts
  - replay
  - positive-control
applies_when:
  - A spec replays one company's idempotency key or operation id under another company's credential
  - The route stores a receipt and answers later replays from it
---

# Make the owner's stored answer differ from the expected answer in cross-tenant replay cases

## Context

A replay case shows that company A cannot get company B's stored receipt back. Company A sends B's exact key and body under A's own credential. The case passes when A gets the expected no-match answer.

That check proves nothing if B's stored answer and the expected answer are the same. On the detach-entries route, B's fresh agent had no entries. So B's own detach stored `{"detached":0}`, which equals the no-match answer `DETACH_NO_MATCH` (`{ status: 200, reason: nil, detached: 0 }`). If the receipt lookup dropped its `company_id` filter, A would get B's receipt back, and it would look exactly like the expected answer. No id would leak and no digest would change.

## Solution

- Arrange the owner's setup so that its stored answer can be told apart from the no-match answer. For detach-entries, the owner's agent first gets one entry, so the owner's receipt reports one detached entry (`tenant_guard_agent_entry`).
- For every replay case, assert this before you trust the result: the owner's recorded status and body must differ from `TenantGuardCases.expected_answer`.
- Before the baseline, read the owner's stored row (the receipt row, or the `invoice_operations` row for prepare, which stores no receipt). Then fail if the requester's answer carries that row's id, the owner's answer, or the stored body, at any depth. Checking only top-level id fields misses a body nested inside a reply such as `{"detached":0,"receipt":{"body":{"detached":1}}}`.

## Why it matters

A replay case exists to catch a receipt leak across companies. If a leaked receipt and a correct refusal give the same answer, the case cannot fail for the bug it is there to catch. Nothing in the case table shows this. You have to ask what the owner actually stored.

## Evidence

- PR #593 adds `tenant_guard_expect_no_owner_receipt` in `spec/integration/timekeeping/tenant_guard_spec.rb`. It asserts that the owner's answer is not equal to the expected answer, then checks ids and nested bodies for leaks.
- In the same file, `tenant_guard_agent_entry` gives the owner's agent an entry before its detach. Its comment says why: a replay that leaks the receipt would then fail the case.
- `spec/support/timekeeping/tenant_guard_cases.rb` in PR #593 defines `DETACH_NO_MATCH = { status: 200, reason: nil, detached: 0 }.freeze` as the detach replay's expected answer.
- `tenant_guard_identifier_lookup` in the spec reads `service_idempotency_receipts` and `idempotency_receipts` with their `body` columns, and reads `invoice_operations` for prepare, commit and abort.

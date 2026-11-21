---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/contracts/timekeeping/idempotency_examples.rb
  - app/services/timekeeping/local_owner.rb
tags:
  - idempotency
  - contract-specs
  - replay-only
  - local-owner
applies_when:
  - Writing a shared contract example that must show whether an idempotency receipt was stored
  - The example runs against both the Timekeeping service and the monolith local owner
---

# Probe for a stored receipt with the same key and a new body across providers

## Context

The shared idempotency examples in `spec/contracts/timekeeping/idempotency_examples.rb` run against every provider, the monolith's local owner included. One example needed to show that a bulk delete that changed nothing stored no receipt. An `Idempotency-Replay: only` retry looks like the obvious probe, because it answers only from a stored receipt. That works against the Timekeeping service. The local owner, though, refuses a replay-only request at its generation check before it reads any receipt, so the probe answers the same way whether or not a receipt exists.

## Solution

Send the same `Idempotency-Key` again with a different body:

- If a receipt was stored, the provider answers `idempotency_key_reused`.
- If none was stored, the new body is evaluated as a first attempt.

In the example, the key is first used on a bulk delete that names only another company's entry. It is then reused to delete the company's own entry, and that delete succeeds. A third call with the same key and body then replays `deleted`, which proves that the delete that changed something stored its receipt. Date the own entry today (`work_date: Date.current.iso8601`) so that an employee's edit window does not refuse the delete for an unrelated reason.

Keep replay-only probes for specs that target only the Timekeeping service, as `timekeeping/spec/requests/v1/entry_writes_tenant_unchanged_spec.rb` does.

## Why it matters

A probe that only one provider answers on the receipt path makes a shared example fail, or pass, for a reason unrelated to receipts. The same-key, new-body check runs through the receipt lookup in every provider, so its answer depends only on whether a receipt exists.

## Evidence

- PR #515 adds the example "stores no receipt for a bulk delete that changed nothing and keeps the receipt of one that did" to `spec/contracts/timekeeping/idempotency_examples.rb`. Its comment says the local owner refuses a replay-only retry at its generation check before it reads any receipt.
- The pull request's record of test edits says this example was first written with a replay-only retry, then changed to reuse the key with a new body for this reason.

---
module: timekeeping tenant guard
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - timekeeping reservations
tags:
  - tenant-isolation
  - operation-id
  - idempotency
  - probe-design
applies_when:
  - An id or key is looked up only within the requesting company
  - A tenant spec swaps in another company's operation id or idempotency key
---

# Test a foreign per-company operation id with cases that cannot write

## Context

Timekeeping stores reservation operation ids per company. The lookup that finds an operation filters on the requester's company. So to company A, an operation id that company B used is simply an unused id.

The tenant guard table had probes for prepare, mark-billed and detach-entries. Each sent A's own invoice or agent with B's operation id and expected 404. The lookup does not find B's id, so each of these requests was a new, valid command for A. Prepare wrote an operation, mark-billed billed A's entries, and detach stored a receipt. These probes could never pass "changes nothing". Making them answer 404 would need a lookup across companies. That lookup would tell A which ids B has used, and it would break the contract rule that a key from another company never matches.

## Solution

Cover a foreign per-company id only with a request the requester's own state already turns away:

- **prepare:** before the probe, the requester prepares its own invoice, which leaves one open operation. The probe then sends B's operation id, and prepare answers 409 `unresolved_operation`, naming A's own operation. The spec sends the same request again with a never-used UUID. It requires the same status, reason and body, and it compares digests around each request on its own. That shows the answer reveals nothing about whether B used the id.
- **mark-billed and detach-entries:** drop the operation-id probes. Their replays send B's recorded body, which names B's invoice or agent, with B's operation id. That id is also the key. Add these two pairs to `REPLAY_PAIRS`. Mark-billed answers 404. Detach answers 200 `detached: 0` and stores no receipt, which counts as no match.

The guard fails when the company filter is removed from the operation lookup. The prepare probe then answers 422 `idempotency_key_reused`.

## Why it matters

A guard that expects 404 for every foreign id pushes authors toward a product change that leaks data across companies, or toward a probe that writes. For ids scoped to a company, "no match" is the right answer. Comparing against a never-used id is what proves that the answer does not reveal the other company's data.

## Evidence

- PR #593 explains this in the header comment of `spec/support/timekeeping/tenant_guard_cases.rb`. It adds `UNRESOLVED_OPERATION`, `DETACH_NO_MATCH`, `REQUESTER_OPEN_OPERATION` and the `PRECONDITIONS` table, and it removes the mark_billed and detach_entries operation-id probe rows.
- `spec/support/timekeeping/tenant_guard_surfaces.rb` adds `%i[reservations mark_billed operation_id]` and `%i[reservations detach_entries operation_id]` to `REPLAY_PAIRS`.
- `tenant_guard_unused_operation_reply` in `spec/integration/timekeeping/tenant_guard_spec.rb` compares the answer to a never-used UUID, with its own digest comparison.
- The PR #593 test plan reports this result: with the company filter removed from find_operation, the prepare probe failed with 422 idempotency_key_reused.

---
module: timekeeping
date: 2026-11-21
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - api_layer
tags:
  - deploy-order
  - additive-field
  - fail-closed
  - reference-client
applies_when:
  - A new caller needs a new field from a response that existing callers already parse
  - The two sides of the call deploy separately
---

# Require a new reference field only in the reader that needs it, and fail closed when it is absent

## Context

Timekeeping and the monolith deploy separately. Every entry write fetches reference facts from the monolith. The detach-entries change needed one new field, `owned_agent_ids`.

If the shared parser had made the field required, a Timekeeping deployed before the monolith would refuse every entry write with `503 reference_unavailable`. If a missing field were read as an empty list, a detach of the company's own agent would be treated as foreign and skip the delete marker.

## Solution

In `timekeeping/app/services/timekeeping/reference_client.rb`:

- The shared validator accepts a response without the field, and checks its shape only when present (`valid_owned_agent_ids?`). `Facts` defaults `owned_agent_ids` to `nil`, so `fetch` and entry writes work beside an older monolith.
- The new reader, `owned_agent_ids`, raises `Unavailable` when the value is `nil`. The caller turns that into `503 reference_unavailable` and stores nothing.
- The new query parameter `agent_ids` is sent only when asked for, so the entry-write request stays byte-for-byte the same.

Then fix the deploy order in the contract: deploy the monolith first, roll Timekeeping back first.

## Why it matters

`nil` (the server did not say) and `[]` (the server said none) are different answers. Collapsing them turns an outage or an old server into a wrong decision that writes a 2xx answer without its safety record. Keeping the requirement in the new reader confines the deploy risk to the new feature, which can fail closed, instead of every existing write.

## Evidence

- PR #570, `timekeeping/app/services/timekeeping/reference_client.rb`: `Facts` takes `owned_agent_ids: nil` by default, `valid_owned_agent_ids?` allows the key to be absent, and `owned_agent_ids` raises `Unavailable` with "reference response lacks owned_agent_ids".
- `timekeeping/spec/services/timekeeping/reference_client_spec.rb` expects `fetch_facts.owned_agent_ids` to be nil for a response without the field, and expects `Unavailable` for a missing, `nil`, non-integer or 500 answer.
- `timekeeping/spec/requests/v1/reservations_tenant_unchanged_spec.rb` stubs a reference answer without `owned_agent_ids` and expects the detach to answer `503 reference_unavailable` with no receipt.
- `contracts/timekeeping/reference.yml` and `docs/architecture/timekeeping-soa.md` section 3.4 state the deploy order: monolith first, Timekeeping rolled back first.

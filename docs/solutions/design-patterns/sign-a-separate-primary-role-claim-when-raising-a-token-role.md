---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: authentication
severity: high
evidence_grounding: anchored
grounding_evidence: 'In PR #151, gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb sets the A6/A7 fact as `employee: user_delegated && primary_role == EMPLOYEE_ROLE` with primary_role a required keyword, timekeeping/lib/timekeeping/token_verifier.rb adds "primary_role" => String to OPTIONAL_CLAIM_TYPES, and timekeeping/spec/services/timekeeping/entry_writer_spec.rb refuses a reserved colleague edit by an admin token whose primary_role is employee'
audience: both
related_components:
  - timekeeping_rules
  - user_token
  - reference_facts
tags:
  - token-claims
  - roles
  - authorization
  - locked-entries
  - rollout
applies_when:
  - Changing which role a Timekeeping user token signs
  - Adding a rule to TimekeepingRules::EntryRules that reads the caller's role
  - Mirroring a monolith permission check that reads a different role than another check
---

# Sign a separate primary-role claim when raising a token's role

## Context

The monolith decides two kinds of entry permission on two different roles:

- Acting for a colleague uses `has_role?(:owner | :admin, company)`. Any owner or admin role in the company counts.
- Editing locked time and changing billed status use `primary_role`. This is the user's lowest-id role in the company.

A user who was an employee first and an admin later passes the first check and fails the second. Timekeeping user tokens used to carry one `role` claim, holding the lowest-id role. Issue #130 asked for that claim to carry the owner or admin role, so colleague targeting works. Raising the only role claim would also have changed rule A6 (no edits to locked entries). A6 refused only when `role == "employee"`, and `EntryWriter` saves through `apply_change` with no further check. So an employee-first admin could have edited a colleague's entry that an invoice had reserved, which the monolith refuses.

## Solution

Give each kind of check its own claim, so each one mirrors the monolith role it copies:

- `role` holds the oldest owner or admin role in the company, or else the oldest role. A1, A3, A4 and A5 read it.
- `primary_role` holds `user.primary_role(company)`. A6 and A7 read it through the `employee` fact in `change_facts`.

Three details stop the raised role from leaking back into the locked and billed rules:

1. `refusing_rules`, `change_decision` and `bulk_decision` take `primary_role:` as a required keyword with no default. A caller that forgets it gets an `ArgumentError`. It cannot quietly reuse `role`.
2. `Identity.user` falls back to `role` only when the claim is absent: `claims.fetch("primary_role") { claims.fetch("role") }`. A token without the claim was signed before this change, when a write token's role was the primary role.
3. `TokenVerifier::OPTIONAL_CLAIM_TYPES` requires `primary_role` to be a String. A `null` or a number is refused as invalid. If it were read as absent, it would fall back to the raised `role`.

Deploy and roll back in an order that never lets an old receiver see a raised role:

- Deploy the Timekeeping that reads `primary_role` before the monolith that signs the raised `role`.
- To roll back, first roll back every monolith process. Then wait at least `UserToken::TTL` (60 seconds) after the last one stops. Only then deploy the older Timekeeping.
- If a rolled-back monolith still signs raised read tokens while `TIMEKEEPING_READ_TOKENS_ENABLED` is on, clear the flag and restart before the wait starts.

## Why it matters

The colleague-target tests pass whether or not the locked rule changed. The extra authority appears only in a different rule that reads the same claim. A single "role" claim cannot copy two monolith checks that read different roles. When you raise a role for one purpose, list every rule that reads it. Each rule whose monolith version reads another role needs its own claim.

The cost is one more claim to sign, verify and thread through `EntryCommand` and `EntryDecision`. The other options were to leave colleague targeting broken or to quietly widen who may edit reserved invoice time. The extra claim is cheaper than either.

## Evidence

- PR #151, `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`: `change_facts` now sets `employee: user_delegated && primary_role == EMPLOYEE_ROLE`, and the three public decision methods take `primary_role:` with no default.
- PR #151, `app/services/timekeeping/user_token.rb`: the payload signs `role: user_facts[:role]` and `primary_role: user.primary_role(company)`.
- PR #151, `timekeeping/lib/timekeeping/identity.rb` and `timekeeping/lib/timekeeping/token_verifier.rb`: the fallback applies only to an absent claim, and the claim must be a String.
- PR #151, `timekeeping/spec/services/timekeeping/entry_writer_spec.rb`: a token with `role: "admin"` and `primary_role: "employee"` gets 403 on a reserved colleague entry and leaves it unchanged. The same token updates an unreserved entry.
- PR #151, `gems/timekeeping_rules/spec/timekeeping_rules/entry_rules/change_decision_spec.rb`: refusing rules are `[:a6]` for that token, and a call without `primary_role` raises `ArgumentError`.
- PR #151, `docs/architecture/timekeeping-soa.md` section 6.2: the deploy order and the step-by-step rollback order.

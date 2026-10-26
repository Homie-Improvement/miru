---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: authentication
severity: high
evidence_grounding: anchored
grounding_evidence: At 8112c17, timekeeping/app/services/timekeeping/write_access.rb refuses any purpose outside WRITE_PURPOSES = [nil, "write"] once ReadAccess allows. timekeeping/lib/timekeeping/token_verifier.rb rejects a non-String purpose through OPTIONAL_CLAIM_TYPES. app/services/timekeeping/entry_api_client.rb mints read tokens only when TIMEKEEPING_READ_TOKENS_ENABLED is "true". docs/architecture/timekeeping-soa.md gives the clear, restart, wait-UserToken::TTL rollback steps.
audience: both
related_components:
  - api_layer
  - infrastructure
tags:
  - signed-token
  - token-purpose
  - role-escalation
  - deploy-order
  - rollback
  - timekeeping
applies_when:
  - A token the monolith signs for Timekeeping gets a different role or wider rights for one kind of request
  - A new claim narrows what a token may do, and an older receiver ignores that claim
  - An optional claim is allowed to be missing for older tokens
---

# A raised token role needs a purpose the receiver enforces, a typed claim, and a staged rollout

## Context

The monolith signs a short-lived token, `Timekeeping::UserToken`, for each delegated call to the Timekeeping service. Timekeeping reads the token's `role` claim on every route. On write routes, `EntryCommand.build` copies that role into the write command.

PR #79 needed a higher role on read tokens. An admin whose older role is `employee` must be able to list a colleague's entries. Raising the role on that token alone would also let its holder write as admin: anyone who captured it could replay it on PATCH or POST before it expired. The two problems below look settled at mint time, but they are not.

1. Labelling a token "read" on the monolith does nothing unless the receiver refuses it on writes.
2. Even after the receiver enforces the label, an older receiver ignores the new claim. Deploy order and rollback then reopen the hole.

## Solution

Put the limit where the credential is accepted, and type it strictly:

- Every token carries a signed `purpose` claim, `"read"` or `"write"`. `UserToken.mint` picks the role with a lookup, `ROLE_FOR_PURPOSE`, keyed by purpose. Any other purpose raises `ArgumentError`, so an unexpected value never falls back to the raised role.
- The read rule counts only `owner` or `admin` roles whose resource is exactly this company: `Role.where(resource: company)`. Global roles and roles in other companies never raise the role.
- Once `ReadAccess.decide` allows the request, `WriteAccess.decide` answers `:forbidden` unless the purpose is `nil` or `"write"`; an expired token still answers `:reference_unavailable`, and another company's path still answers ReadAccess's refusal (such as `:not_found`), whatever the purpose. A missing purpose is allowed only because tokens signed before this change carry the primary role, as before.
- Because a missing purpose may write, `TokenVerifier` rejects a purpose that is present but not a String (`OPTIONAL_CLAIM_TYPES`). Otherwise a wrong-type value could be read as missing and gain write access.

Then stage the rollout, because the monolith and Timekeeping deploy apart:

- The monolith mints raised read tokens only when `TIMEKEEPING_READ_TOKENS_ENABLED` is `"true"`. Until then, reads send the default write token with the primary role.
- Set the flag only once every running Timekeeping refuses read tokens on write routes.
- Before rolling Timekeeping back to a version that ignores `purpose`: clear the flag on every monolith process and restart them. Then wait at least `UserToken::TTL` (60 seconds) after the last restart. Only then deploy the older Timekeeping. Clearing the flag stops new tokens only; tokens already issued stay valid until they expire.

## Why it matters

A claim that narrows a token's use is checked only by a receiver that knows the claim. Merge order inside one pull request does not decide which application deploys first. Without the flag, a monolith deploy ahead of Timekeeping would issue admin-role tokens that the old write path accepts. A colleague's entries, or locked entries, could then change with nobody deciding to allow it.

The same reasoning holds for any "absent means legacy, so allow" rule. That rule is only safe when a malformed value cannot be treated as absent.

The other option was to change `User.primary_roles_for`, where the lowest-id role wins. Issue #66 deferred that as an identity decision, because the rule also drives billed and locked checks and the reference endpoint. A purpose claim costs one claim and one check on the write path. Changing the shared role rule would change behavior in places this fix does not need to touch.

## Evidence

- Head commit 8112c17133de06a43acc18bed94b80167561bb02 of PR #79, which closes issue #66.
- `app/services/timekeeping/user_token.rb`: `ROLE_FOR_PURPOSE`, `PRIVILEGED_ROLES` loaded from `contracts/timekeeping/entry_api.yml`, `held_role_names` filtered by `Role.where(resource: company)`, and the `purpose` payload claim.
- `timekeeping/app/services/timekeeping/write_access.rb`: `WRITE_PURPOSES = [nil, "write"]`, checked after `ReadAccess.decide` allows the request.
- `timekeeping/lib/timekeeping/token_verifier.rb`: `OPTIONAL_CLAIM_TYPES = { "purpose" => String }`, with a comment explaining that a wrong-type purpose must not be read as missing.
- `app/services/timekeeping/entry_api_client.rb`: `READ_TOKENS_ENV = "TIMEKEEPING_READ_TOKENS_ENABLED"` and `token_purpose`, which returns `:write` unless the flag is `"true"`.
- `docs/architecture/timekeeping-soa.md`: the environment table row with the clear, restart, and wait-for-`UserToken::TTL` rollback steps.
- Tests: `timekeeping/spec/requests/v1/entries_auth_spec.rb` replays a read token on PATCH, POST and DELETE and gets 403 with no entry changed. `timekeeping/spec/services/timekeeping/write_access_spec.rb` checks the purpose table (`nil`, `write`, `read`, `bogus`, empty, `READ`). `spec/services/timekeeping/entry_api_client_spec.rb` checks that the default token keeps the primary role while the flag is unset or `"false"`.

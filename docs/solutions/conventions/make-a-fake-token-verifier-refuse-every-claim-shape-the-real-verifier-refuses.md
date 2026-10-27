---
module: timekeeping
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: app/services/timekeeping/service_token.rb adds CLAIM_RULES copied from Timekeeping's verifier and verify checks them; spec/contracts/timekeeping/fake_timekeeping_spec.rb expects 401 for a correctly signed token whose operations claim is a single string
audience: both
related_components:
  - authentication
tags:
  - test-fake
  - jwt
  - service-token
  - contract-parity
applies_when:
  - A test fake verifies signed tokens through a monolith-side verify method instead of the real service's verifier
  - The real verifier checks claim types, not only the signature
---

# Make a fake token verifier refuse every claim shape the real verifier refuses

## Context

`TimekeepingContract::FakeTimekeeping` stands in for the Timekeeping service in specs. In token mode it verifies a `Timekeeping::ServiceToken` with `ServiceToken.verify`, because the monolith cannot load the service's own verifier.

The first version of `verify` checked the signature but then coerced the claims, turning an `operations` string into an array. The real service verifier needs `operations` to be an array of strings, `sub` to be a non-empty string, and `company_id` to be an integer. So a correctly signed token with `"operations": "agents.detach_entries"` passed the fake and would fail in production.

## Solution

Check claim shapes in the shared verifier and drop the coercion:

```ruby
CLAIM_RULES = {
  "typ" => ->(value) { value == TYPE },
  "sub" => ->(value) { value.is_a?(String) && !value.empty? },
  "company_id" => ->(value) { value.is_a?(Integer) },
  "operations" => ->(value) { value.is_a?(Array) && value.all?(String) }
}.freeze
```

`verify` raises `InvalidTokenError` unless every rule passes. Keep a comment naming the real verifier the rules mirror, so the two are compared when either changes.

Test the fake with tokens you sign by hand with `JWT.encode`, not only with the minter. The minter always emits valid shapes, so it cannot show a gap. Cover a scalar `operations`, a non-string operation, an empty or integer `sub`, and a string `company_id`, and check that the fake answers 401 and changes no entry.

This was seen for the RS256 service token. The fake's user-token path was not changed here, so check it separately before assuming the same holds.

## Why it matters

A fake that is looser than production makes integration specs prove less than they claim. The gap stays hidden while today's sender happens to emit valid shapes, and shows up only in production when a sender changes. Coercion in a verifier is the usual cause: it is a convenience for the reader that turns a refusal into a pass.

## Evidence

- PR #207, `app/services/timekeeping/service_token.rb`: `CLAIM_RULES`, its comment naming Timekeeping's own verifier, and the check in `self.verify`; `claims_from` reads `operations` without `Array` coercion.
- PR #207, `spec/support/timekeeping/fake_timekeeping.rb`: `signed_service` verifies through `Timekeeping::ServiceToken.verify` and grants only operations in `BACKGROUND_OPERATIONS`.
- PR #207, `spec/contracts/timekeeping/fake_timekeeping_spec.rb`: the `scalar_operations` token, correctly signed with RS256, expects status 401 and the entry keeps its `agent_id`.
- PR #207, `spec/services/timekeeping/service_token_spec.rb`: "refuses a signed token whose claims have a shape Timekeeping's verifier rejects".
- A build-review finding on PR #207 reported the fake accepting a scalar `operations` claim; the author's recorded run of `spec/contracts/timekeeping/fake_timekeeping_spec.rb` and `spec/services/timekeeping/service_token_spec.rb` passed after the fix.

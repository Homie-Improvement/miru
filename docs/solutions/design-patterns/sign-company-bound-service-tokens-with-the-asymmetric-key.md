---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: authentication
severity: high
evidence_grounding: anchored
grounding_evidence: timekeeping/lib/timekeeping/service_token_verifier.rb pins RS256 and requires typ timekeeping_service; timekeeping/spec/lib/timekeeping/identity_spec.rb checks that a token HS256-signed with the shared service token resolves as invalid.
audience: both
related_components:
  - identity
  - credential_scan
tags:
  - service-token
  - jwt
  - key-reuse
  - tenant-isolation
applies_when:
  - Adding a token that binds a background caller to one company or a list of operations
  - A shared secret already travels as a plain bearer between services
---

# Sign company-bound service tokens with the asymmetric token key, not the shared bearer

## Context

PR #63 added a short-lived service token that binds a background caller to one `company_id` and a list of allowed operations. The issue named `TIMEKEEPING_SERVICE_TOKEN` as the credential, so the first design signed the token with HMAC (HS256) using that value as the key.

That value is also sent as a plain bearer on every reference read and is accepted raw by internal routes. Anyone who has seen it can mint an HMAC token for any company with every operation. The company binding then protects nothing against those callers.

The HMAC choice also needed its own detector in the credential scan, which stops users saving a token into an entry note. That detector assumed every header starts with `eyJ`, and a valid token with a header like `{ "alg"` passed through.

## Solution

Sign service tokens RS256 with the monolith's existing token private key. Verify with the public key that already verifies user tokens. Separate the two kinds by claims:

- A service token must carry `typ: "timekeeping_service"`, a string `sub`, an integer `company_id` and an `operations` array.
- A user token has no `typ` and needs an integer `sub` and a role.

`Identity.signed` tries the service verifier first and falls back to the user verifier, so neither kind verifies as the other. The algorithm is fixed in code, never read from the header. The existing credential scan already finds any segment that is a valid RS256 signature by that key, so service tokens are caught whatever their header holds, and no second scan is needed.

The raw shared token keeps working as the unbound service identity. It carries no company and no operations, so the new routes refuse it.

## Why it matters

Reusing a secret that is already a bearer feels like following the spec, and a reviewer had to raise it twice before it changed. The cost is a full tenant break for anyone who sees one request's headers. Reusing the asymmetric key also removes code: one verifier key and one signature scan cover both token kinds.

## Evidence

- PR #63, head commit af7ba08d467267850f5c5fc9ac3091d3cf237d0a.
- `timekeeping/lib/timekeeping/service_token_verifier.rb`: `ALGORITHM = "RS256"`, `TYPE = "timekeeping_service"`, `CLAIM_RULES`, and the module comment on why the key is never a value sent as a bearer.
- `timekeeping/lib/timekeeping/identity.rb`: `signed` tries `ServiceTokenVerifier`, then `TokenVerifier`.
- `timekeeping/spec/lib/timekeeping/identity_spec.rb`: "refuses a service token signed with the shared service token as an HMAC secret".
- `timekeeping/spec/services/timekeeping/credential_scan_spec.rb`: the "for signed service tokens" example finds a token whose header is `{ "alg": "RS256", "typ": "JWT" }` with spaces.
- `timekeeping/app/services/timekeeping/reservation_access.rb`: the raw shared token lists no operation, so it is refused.

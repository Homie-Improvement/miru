---
module: timekeeping
date: 2026-10-25
problem_type: design_pattern
component: authentication
severity: medium
evidence_grounding: anchored
grounding_evidence: timekeeping/lib/timekeeping/token_verifier.rb adds ExpiredToken#company_id, set only after JWT::ExpiredSignature and typed_claims?; timekeeping/lib/timekeeping/identity.rb adds signed_company_id while company_id stays nil for :expired; identity_spec.rb and entry_write_metrics_spec.rb assert both
audience: both
related_components:
  - observability
  - api_layer
tags:
  - jwt
  - expired-token
  - metrics
  - attribution
  - authorization
applies_when:
  - Counting or logging refusals per tenant where some refusals come from expired tokens
  - Adding any per-company bookkeeping that runs before or after an access decision
---

# Key refusal metrics on the signed company, kept apart from the access company

## Context

The Timekeeping entry write routes answer an expired user token with `503 reference_unavailable`. Operators alert when that 503 passes 1% of a company's writes. The metric must be keyed only on a company that a caller cannot fake, so a request without a verified signature records nothing.

Before this change, `Identity.resolve` turned an expired token into `anonymous(:expired)` with `company_id: nil`. The token's claims were thrown away. So the easy design counted nothing for expired tokens. If a company's tokens all expired, every write failed with 503 and the metric showed no failures at all.

The opposite shortcut is also wrong. Putting the expired token's company into `company_id` would feed it to `WriteAccess`, `ReadAccess` and the `RequestIdentity` log tags. Those all treat a non-nil `company_id` as a verified caller.

## Solution

Separate two questions: "who signed this?" and "may this caller act?".

1. In `Timekeeping::TokenVerifier`, the jwt gem checks the signature before `exp`. So `JWT::ExpiredSignature` is raised only for a token the monolith really signed. On that error, decode the token again with the same key and algorithm and `verify_expiration: false`. Apply the same claim type check (`typed_claims?`). Then raise `ExpiredToken` with a `company_id` reader, or `nil` when the claim types fail. A forged token still raises `InvalidToken` and carries no company.
2. `Timekeeping::Identity` gains `signed_company_id`, which defaults to `nil`. For a verified user it equals `company_id`. For `anonymous(:expired)` it holds the expired token's company. For every other identity, including the service, it is `nil`. `company_id` stays `nil` for an expired token.
3. Only the metric hook (`Timekeeping::WriteMetricsRecording`) reads `signed_company_id`. Access decisions and log tags keep reading `company_id`. The hook never reads the path's `company_id`, so a request to another company's path is counted under the token's own company.

The trade-off is stated, not hidden. Anyone holding a company's leaked expired token can raise that company's refusal count. Raising another company's count still needs the signing key. The other choice was to drop expired-token refusals, which costs a blind spot during the exact outage the alert exists for. Keeping the signed company is the better choice.

## Why it matters

"Signature verified" and "allowed to act" are different facts. Code that merges them into one field must pick wrong in one direction. Either the refusals vanish from monitoring, or an expired caller's company starts to reach access checks. A separate field that names its one purpose keeps both correct. A future change that reads `signed_company_id` for anything other than attribution brings back the access risk. Reviewers should check every new reader of that field.

## Evidence

All from PR #45 at head commit 317701e40c135c8db5470f92f351d5f371db582e:

- `timekeeping/lib/timekeeping/token_verifier.rb`: `ExpiredToken` gains `attr_reader :company_id`. `verify` rescues `JWT::ExpiredSignature` and calls `expired_company_id`, which decodes with `verify_expiration: false` and returns `payload["company_id"] if typed_claims?(payload)`, else `nil`.
- `timekeeping/lib/timekeeping/identity.rb`: `Identity` adds the `signed_company_id` member with a `nil` default. `resolve` rescues `ExpiredToken => e` and builds `anonymous(:expired, signed_company_id: e.company_id)`. `user(claims)` sets both fields from the `company_id` claim.
- `timekeeping/app/controllers/concerns/timekeeping/write_metrics_recording.rb`: the `ensure` block records only when `identity.signed_company_id` is present.
- `timekeeping/spec/lib/timekeeping/identity_spec.rb`: an expired token has `company_id: nil` and `signed_company_id: 9`, and `RequestIdentity.company_tag` still answers `"unverified"`. A forged expired token and the service token give `nil`.
- `timekeeping/spec/lib/timekeeping/token_verifier_spec.rb`: an expired token with `company_id: "9"` (wrong type) carries no company.
- `timekeeping/spec/requests/v1/entry_write_metrics_spec.rb`: a validly signed expired token sent to another company's path gets 503 and counts `[0, 1]` under the token's company only. An expired token signed with another key gets 401 and creates no row.
- The PR body records the leaked-expired-token risk as a concern about the written rule.

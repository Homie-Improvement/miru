---
module: users_signup
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - devise
  - pwned
tags:
  - signup
  - pwned-password
  - outbound-http
  - request-specs
applies_when:
  - A request spec posts to api_v1_users_signup_path with a password
  - A spec depends on signup timing or on how many signups run in a time window
---

# Stub the breached-password lookup in signup request specs

## Context

Signup checks the new password against an outside breached-password service through `Pwned::Password`. Request specs in this repository allow real HTTP, so a spec that posts to signup calls that service on every request. On a runner with network access each call can wait on the service. In a sandbox without DNS the call fails in milliseconds, so the dependency is hard to notice locally. Login and password recovery set no password and skip the call.

## Solution

Stub the lookup in the spec, so no signup leaves the test process:

```ruby
before do
  allow(Pwned::Password).to receive(:new)
    .and_return(instance_double(Pwned::Password, pwned_count: 0))
end
```

Keep the stub inside the spec file that needs it. The password check stays active for real signups and for specs that test it.

## Why it matters

A spec that sends several signups in a row, such as a throttle spec, depends on how long each request takes. Real outbound calls make that time depend on the runner's network, not on the code. The result is a spec that behaves differently in CI than on a laptop.

## Evidence

- PR #166 adds this stub to `spec/requests/rack_attack/auth_throttle_spec.rb`, with a comment saying request specs allow real HTTP and each signup would otherwise wait on the breached-password service.
- The suite-wide setting that allows real HTTP is unchanged by PR #166; the plan defers whether request specs should allow outbound HTTP at all.
- Graded speculative: the Devise configuration and the HTTP setting live in files outside this change, and the PR does not confirm that the network call caused the CI failure in issue #157.

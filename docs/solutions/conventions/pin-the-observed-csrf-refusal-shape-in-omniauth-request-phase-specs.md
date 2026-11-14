---
module: authentication
date: 2026-11-14
problem_type: convention
component: authentication
severity: medium
audience: both
related_components:
  - testing_framework
tags:
  - omniauth
  - csrf
  - request-specs
  - dependency-upgrade
applies_when:
  - Writing or reviewing a request spec that checks OmniAuth sign-in requests are refused without a valid authenticity token
  - Upgrading omniauth or omniauth-rails_csrf_protection
---

# Pin the observed CSRF refusal shape in OmniAuth request-phase specs, and add a protection-off control

## Context

The sign-in request phase is the POST to `/users/auth/github` or `/users/auth/google_oauth2`. It must refuse a request that has no valid authenticity token. A forged sign-in request is a login CSRF attack, which this check exists to stop. The check runs inside the OmniAuth middleware, through the verifier in `config/initializers/omniauth_rails_csrf_protection.rb`. So it can break silently when OmniAuth is upgraded.

A spec for this check has two traps:

- Forgery protection is off in the test environment. A spec that leaves it off never runs the check.
- The refused response is easy to guess wrong. OmniAuth's upstream code rescues errors in the request phase and calls `fail!`, and Devise's failure action then redirects to the root path. A reviewer reading that code expected a 302 redirect. On omniauth 2.4.0 in this app, with OmniAuth `test_mode` on, a check made while building the change got status 422 and no `Location` header.

## Solution

In `spec/requests/users/omniauth_callbacks/request_phase_csrf_spec.rb`:

1. An `around` block saves `ActionController::Base.allow_forgery_protection`, sets it from a `let(:forgery_protection) { true }`, and restores it in `ensure`. Turning it on inside the spec only, and restoring it after, stops the global change from reaching other specs.
2. A refusal counts only when the request raises `ActionController::InvalidAuthenticityToken` or answers `422`:

```ruby
def refused_sign_in_request?(path, params: {})
  post(path, params:)
  response.status == 422
rescue ActionController::InvalidAuthenticityToken
  true
end
```

Any other status does not count as a refusal: a redirect onward, a 404 or a 500. A loose check such as "did not redirect to the callback" would also pass on a broken route or a crash.

3. Each provider also has an example that sends a real token taken from the page's `csrf-token` meta tag. That example expects a redirect to the callback. Without it, a verifier that refuses every request would still pass the spec.
4. A `context "when forgery protection is off"` example sets `forgery_protection` to `false` and expects the same request to reach the mock callback. This shows that the refusals come from the CSRF check, not from a request phase that is broken for some other reason.

If a future OmniAuth version changes the refusal shape, for example to a failure redirect, first run one tokenless POST and record the status and location. Then change the helper to match that shape. Do not widen it to cover every possible shape.

## Why it matters

A helper that accepts every possible refusal shape cannot tell a CSRF refusal apart from an unrelated failure. Changing a correct 422 check to a redirect check because of what upstream code suggests would make three correct examples fail. The protection-off control and the valid-token examples hold the spec on both sides: it fails if the check stops refusing, and it fails if the check refuses everything.

## Evidence

- PR #280 upgrades omniauth from 2.1.4 to 2.4.0 in `Gemfile.lock` and adds `spec/requests/users/omniauth_callbacks/request_phase_csrf_spec.rb`. That spec has the `around` block, the `refused_sign_in_request?` helper, the valid-token examples and the protection-off context described above.
- The spec's own comment says the verifier raises `ActionController::InvalidAuthenticityToken`. It also says Rails answers that error with 422 because `show_exceptions` is `:rescuable` in `config/environments/test.rb`.
- A review comment on this pull request argued that OmniAuth turns the refusal into a failure redirect. The author checked this with omniauth 2.4.0 loaded. A tokenless POST to `/users/auth/github` with forgery protection on returned `PROBE status=422 location=nil`. The spec file passed with 7 examples and 0 failures.
- The PR body says that switching off OmniAuth's request validation hook for one run made the three refusal examples fail.

---
module: authentication
date: 2026-11-14
problem_type: design_pattern
component: authentication
severity: medium
audience: both
related_components:
  - configuration
  - omniauth
tags:
  - omniauth
  - full-host
  - host-header
  - oauth-callback
  - boot-validation
applies_when:
  - Configuring OmniAuth or any OAuth sign-in that builds a callback URL
  - Adding a base URL setting that can be unset in some environment
---

# Pin OmniAuth's full host to a validated string at boot

## Context

OmniAuth builds each OAuth callback URL from `OmniAuth.config.full_host`. When that setting is unset, OmniAuth takes the host from the request's `Host` and `X-Forwarded-*` headers. A forged header can then point the callback, and the provider's authorization code, at another host.

Before PR #288, `config/initializers/devise.rb` set `full_host` only when `APP_BASE_URL` was non-blank. Any environment without that variable fell back to the request-derived host, and nothing said so.

## Solution

Set `full_host` in one place, at boot, and never leave it unset:

- Pick `APP_BASE_URL` when it is non-blank. Whitespace counts as unset.
- Otherwise use `config.x.default_base_url`, which every `config/environments/*.rb` file declares.
- Require an absolute `http` or `https` URL with a host. Anything else raises `OmniauthFullHost::InvalidBaseUrl` and stops boot. There is no fallback to the request.
- In production, require `https` as well. The boot call passes `require_https: Rails.env.production?` to `resolve`, and an `http` base URL from either source raises `OmniauthFullHost::InvalidBaseUrl`. Production forces SSL, so an `http` base URL there would only send OAuth codes and emailed links over plain http. The error names the source and the scheme, never the full URL, so a password embedded in it stays out of boot logs. Development and test keep their `http` defaults.
- Strip trailing slashes, because OmniAuth appends the callback path and would double the slash.
- Assign the result as a plain String, not a lambda:

```ruby
def self.pin!(base_url)
  OmniAuth.config.full_host = base_url
end
```

A lambda receives the Rack env on every call, so request data stays one edit away from the callback URL. A String never sees the request, so the pin holds even if a later OmniAuth release regresses its own Host-header handling.

In production, keep the fallback literal in one local so host authorization and OmniAuth share it.

To prove the pin in a request spec, include a control: clear `full_host` to `nil`, send a forged `Host`, and assert the callback host is the forged one. Without that control, a pinned assertion could pass simply because the host was never read. Test forged `X-Forwarded-Host` and `X-Forwarded-Proto` too, since OmniAuth's fallback reads them as well.

## Why it matters

A missing environment variable should never quietly change where sign-in sends authorization codes. Failing at boot turns a silent security gap into a deploy error someone sees at once. Keeping one file that sets `full_host` means a reviewer can confirm the pin with one search.

## Evidence

- PR #288 adds `config/initializers/omniauth_full_host.rb` with `OmniauthFullHost.resolve`, `pin!` and `validate!`, and removes the conditional lambda block from `config/initializers/devise.rb`.
- PR #288 declares `config.x.default_base_url` in `config/environments/development.rb`, `config/environments/test.rb` and `config/environments/production.rb`; production reuses one `default_base_url` local for both `ENV.fetch("APP_BASE_URL", ...)` and the new setting.
- `spec/requests/users/omniauth_callbacks/full_host_pin_spec.rb` shows the control: with `full_host` set to `nil`, a `Host: evil.example` request redirects to `evil.example`; after the initializer loads, the callback is `http://example.com/users/auth/github/callback`, including with forged `X-Forwarded-*` headers.
- `spec/initializers/omniauth_full_host_spec.rb` checks that `pin!` leaves a value that does not respond to `call`, and that `example.com`, `ftp://example.com` and `http://` raise `OmniauthFullHost::InvalidBaseUrl`.
- `spec/initializers/omniauth_full_host_spec.rb` and `spec/initializers/omniauth_full_host_2_spec.rb` stub `Rails.env` to production and check that the initializer refuses to boot on an `http` APP_BASE_URL or fallback and boots on an `https` one, and that `resolve` without `require_https` still accepts `http`.

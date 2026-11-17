---
module: stripe_connect
date: 2026-11-15
problem_type: convention
component: payments
severity: medium
audience: both
related_components:
  - app_base_url
  - routing
tags:
  - app-base-url
  - url-helpers
  - stripe-connect
  - absolute-urls
applies_when:
  - Building an absolute link for an external service (Stripe, OAuth callbacks, mail) from the app's base URL
  - Replacing a raw ENV['APP_BASE_URL'] read with AppBaseUrl.current
---

# Join the resolved base URL with a path helper instead of passing it as `host:`

## Context

`StripeConnectedAccount#url` sends Stripe two links: a refresh link and a return link. It built the refresh link as `payments_settings_stripe_connect_refresh_url(host: "#{ENV['APP_BASE_URL']}")`. With APP_BASE_URL unset, Stripe got a refresh link with no host and the relative return link "/settings/payment".

APP_BASE_URL holds a full URL, including the scheme and possibly a path. The `host:` option of a Rails `_url` helper expects a host. The plan for this change says that a full URL passed as `host:` has its scheme split out, and that a path prefix would be lost. The change itself does not show that part.

## Solution

Read the base URL once from `AppBaseUrl.current`, the app's one base-URL resolver. Then add the route's `_path` output to it:

```ruby
base_url = AppBaseUrl.current
refresh_url: "#{base_url}#{payments_settings_stripe_connect_refresh_path}",
return_url: "#{base_url}/settings/payment"
```

The QuickBooks configuration and the mailers already build links this way. Pin each link in the spec as an exact string. An exact string fails on a doubled slash, a lost scheme or a doubled scheme. A substring match does not.

## Why it matters

The resolver handles the fallback, trims a trailing slash and rejects malformed values. A `_url(host:)` call skips that work and hands the URL to Rails. If you swap in `AppBaseUrl.current` but keep the `host:` form, the code still looks centralized, but the link shape depends on how Rails parses `host:`. That is not what the resolver promises.

## Evidence

- PR #309 changes `app/models/stripe_connected_account.rb` from `payments_settings_stripe_connect_refresh_url(host: ...)` to `"#{base_url}#{payments_settings_stripe_connect_refresh_path}"`, with `base_url = AppBaseUrl.current`.
- `spec/models/stripe_connected_account_spec.rb` in this pull request checks the exact refresh URL `https://boot-check.test/payments/settings/stripe/connect/refresh` when APP_BASE_URL is unset. With `https://app.example.test/` (a trailing slash), it checks for `https://app.example.test/payments/settings/stripe/connect/refresh`.
- The PR body says the old code sent Stripe a refresh link with no host and a relative return link when APP_BASE_URL was unset.
- The scheme-splitting and path-prefix behavior of `host:` is the plan's reasoning. This change does not test it. To confirm it, call a `_url` helper with `host: "https://x.test/prefix"` in a console.

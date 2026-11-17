---
module: base URL resolution
date: 2026-11-15
problem_type: design_pattern
component: mailers
severity: medium
audience: both
related_components:
  - app/services/subscriptions/stripe_sync_service.rb
  - app/mailers/subscription_mailer.rb
  - config/initializers/app_base_url.rb
  - app/mcp/api_proxy.rb
tags:
  - app-base-url
  - single-source-of-truth
  - mailer-params
  - fallback
applies_when:
  - A reader is changed to take a value from one shared resolver such as `AppBaseUrl.current`
  - The reader still accepts a caller-supplied value ahead of the shared default, for example `params[:x].presence || default`
---

# Remove caller-supplied overrides when you centralize a default

## Context

PR #293 made every email link take its base URL from `AppBaseUrl.current`. That function returns APP_BASE_URL when it is set and not blank, and `config.x.default_base_url` otherwise. `SubscriptionMailer#plan_purchased` was changed to read:

```ruby
@billing_url = params[:billing_url].presence || "#{AppBaseUrl.current}/settings/billing"
```

The mailer edit looked complete. But its only caller, `Subscriptions::StripeSyncService#notify_plan_purchase!`, always passed `billing_url: "#{ENV['APP_BASE_URL']}/settings/billing"`. When APP_BASE_URL is unset, that string is the relative path `/settings/billing`. `presence` treats it as a real value. The shared fallback never ran in production, and the purchase alert kept its relative link.

## Solution

When you move a reader onto a shared resolver, search for callers that supply the same value as an argument, a param or a header. Then do one of two things:

- Remove the caller's argument so the reader always uses the shared value. PR #293 did this: `stripe_sync_service.rb` no longer passes `billing_url`.
- If the override has to stay, build it from the shared resolver too, never from raw ENV.

Then add a test that goes through the real caller, or that calls the reader without the override. The test should swap `config.x.default_base_url` to a distinct value with APP_BASE_URL deleted. A test that calls only the reader with the override missing does not prove what production sends.

The same risk applies when caller values are merged over a reader's defaults. `MCP::Miru::ApiProxy` used to merge request headers over its default `HTTP_HOST`, and `BaseTool` passed the client's Host through that merge. PR #310 removed the merge and the `headers:` keyword (see `docs/solutions/conventions/prove-a-proxy-set-host-through-a-real-tool-call-not-only-the-proxy.md`). Before you claim a reader uses the shared value, check whether any caller passes its own value over it.

## Why it matters

The broken link appears only when APP_BASE_URL is unset. Specs that call the mailer directly without the param still pass, so the bug survives review and CI. A caller-supplied override bypasses the resolver's checks: no fallback, no blank handling, and no rule that the URL must be absolute.

## Evidence

- PR #293 removes the `billing_url: "#{ENV['APP_BASE_URL']}/settings/billing"` argument from `notify_plan_purchase!` in `app/services/subscriptions/stripe_sync_service.rb`.
- In the same PR, `app/mailers/subscription_mailer.rb` keeps `params[:billing_url].presence || "#{AppBaseUrl.current}/settings/billing"` in `plan_purchased`.
- `spec/mailers/subscription_mailer_spec.rb` adds the example "links the plan purchased email to the swapped config.x.default_base_url billing page when no billing_url is given". Its comment says `Subscriptions::StripeSyncService` passes no `billing_url`. The example checks `https://boot-check.test/settings/billing` in both the HTML and text parts.
- Later, PR #310 confirmed the header case: the MCP tool layer passed the request's `Host` header, and `app/mcp/api_proxy.rb` merged it over its default `HTTP_HOST`. That PR removed the override.

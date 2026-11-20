---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - TimekeepingRegressionAdapter
  - TimekeepingContract::FakeHttpBridge
tags:
  - timekeeping
  - webmock
  - regression-adapter
  - spec-helpers
  - fake
applies_when:
  - Adding or moving a check that must stop specs from answering Timekeeping HTTP with the in-process fake while TimekeepingRegressionAdapter runs
  - Writing a spec that proves a helper routed nothing to a fake
---

# Guard the live regression adapter in the shared fake routing helper

## Context

Some spec runs use `TimekeepingRegressionAdapter`. In those runs, specs must talk to a live Timekeeping app, not to the in-process fake. If the fake still answers, the spec passes while the live app is never used, and the run reports a false result.

The guard first lived only in `arrange_forwarded_timekeeping`. That is a wrapper. Many specs skip it and call `route_timekeeping_to_fake` directly: the agent spec, the entry write client spec, and the gateway specs, about 80 call sites. Those specs bypassed the guard completely.

## Solution

Put the check once, at the top of the helper that registers the WebMock stub:

```ruby
def route_timekeeping_to_fake(fake, base_url:)
  return if TimekeepingRegressionAdapter.current
  ...
```

Now every caller gets the check, including callers added later. The wrapper keeps its own early return, because that return also skips the `fake.register_*` calls. Calling the guard twice is harmless.

A direct caller that still expects the fake now fails loudly under the adapter. That failure is intended. Making those specs pass against the live app is separate work.

To prove that nothing was routed, check the stub registry. Do not check the fake's request log:

- `WebMock::StubRegistry.instance.request_stubs.size` is unchanged after the call.
- `registered_request?` returns nil for a request to every host that was passed in. Include the live app's own `base_url`, because a stub on that host would send live traffic to the fake.

Also prove the other path. With `current` stubbed to nil, the call must add exactly one stub, and a real client request must be answered by the fake.

## Why it matters

A guard in a wrapper protects only the specs that use the wrapper. The helper underneath it is the real way into the fake, so the guard belongs there.

When no request is sent, the fake's request log stays empty whether or not the guard is there. So `expect(fake.requests).to be_empty` passes with or without the guard. Only the stub-registry checks fail when the guard is gone.

## Evidence

- PR #471 adds `return if TimekeepingRegressionAdapter.current` at the top of `route_timekeeping_to_fake` in `spec/support/timekeeping/fake_http_bridge.rb`. It also adds a comment that says why the live app owns the connection during a regression run.
- PR #471 adds `spec/contracts/timekeeping/fake_http_bridge_spec.rb`. Its live-adapter example routes to `http://timekeeping.test` and to the adapter's `base_url`. It then asserts that the stub count is unchanged and that `registered_request?` is nil for a GET to `/api/v1/entries` on both hosts. Its no-adapter example asserts one new stub, and checks that `Timekeeping::EntryApiClient#list_entries` gets the fake's entry back.
- In review of PR #471, the first live-adapter examples asserted `fake.requests` was empty without sending any request. They were merged into one example that uses the stub-registry checks above. With the guard line deleted, the author's run gave 2 examples and 1 failure: the merged live-adapter example.

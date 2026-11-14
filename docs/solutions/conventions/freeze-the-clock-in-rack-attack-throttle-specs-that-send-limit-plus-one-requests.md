---
module: spec/requests/rack_attack
date: 2026-11-14
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - rack_attack
tags:
  - rack-attack
  - throttle
  - flaky-test
  - freeze-time
  - request-specs
applies_when:
  - A spec sends a Rack::Attack throttle's limit of requests and expects the next one to get 429
  - A new throttle or a new throttle spec is added under spec/requests
---

# Freeze the clock in Rack::Attack throttle specs that send limit plus one requests

## Context

Rack::Attack counts throttled requests in fixed time windows. Each window has its own counter, and the window is chosen from the current time. The auth throttles in this repository use one-minute windows.

A throttle spec typically sends the limit of requests, then one more, and expects that last one to get `429 Too Many Requests`. If the requests start in one minute and end in the next, the counter resets partway through. The over-limit request is then counted as an early request in a fresh window, and it gets the normal response instead.

In CI this showed up as `expected ... :too_many_requests (429) but it was :unprocessable_content (422)` on the login example. That example sends 20 failed logins and expects the 21st to be throttled. It passed alone and in repeated local runs, because a run only fails when it happens to cross a minute boundary. A slow, cold first request makes that more likely.

## Solution

Wrap every example of a throttle spec in a frozen clock, using the block form so the clock is released when the example ends:

```ruby
around do |example|
  freeze_time { example.run }
end
```

Any frozen instant works. Once the clock cannot move, every request reads the same time and lands in the same window, so travelling to the start of a minute adds nothing. The block form matters because the clock is restored after each example. With the non-block form, a later spec in a random-order run could run under a frozen clock.

Apply the hook to the whole file, not only to the example that failed. Every example that counts up to a limit has the same exposure. In `spec/requests/rack_attack/auth_throttle_spec.rb` that means the recovery example (10 requests, then 429) and the signup example (5, then 429) as well as login.

A green run cannot prove the fix, because the flaky spec was already green most of the time. To prove it, add a temporary step that moves the frozen clock forward one minute (`travel 1.minute`) between the last allowed request and the over-limit one. The 429 assertion should then fail. Remove the step afterwards.

Other throttle specs that send limit plus one requests without controlling time carry the same risk and need the same hook.

## Why it matters

This failure looks like noise, so it tends to be rerun rather than fixed. It costs CI time and trust each time it happens. It also hides real throttle regressions, because a reviewer learns to ignore 422-versus-429 failures on these specs. Freezing the clock makes the spec pass or fail on throttle behaviour alone.

## Evidence

- PR #265 adds an `around` hook running `freeze_time { example.run }` to `spec/requests/rack_attack/auth_throttle_spec.rb`. The comment it adds states that Rack::Attack counts each throttle in fixed one-minute windows keyed on `Time.now`, and that freezing the clock stops a minute boundary from resetting the count before the over-limit request.
- The PR #265 test plan reports that the auth throttle file passed with seeds 1, 2 and 3. It also reports that a temporary copy, which moved the frozen clock forward one minute between the 20th and 21st login, failed its login example as expected. That copy was not committed.
- Issue #264, which PR #265 closes, records the CI failure: 429 was expected but 422 came back at `spec/requests/rack_attack/auth_throttle_spec.rb:32`, while the example passed locally alone and across whole-file runs.

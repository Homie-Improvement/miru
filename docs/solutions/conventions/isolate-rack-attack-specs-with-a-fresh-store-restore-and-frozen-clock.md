---
module: rack_attack
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - config/initializers/rack_attack.rb
tags:
  - rack-attack
  - throttle
  - test-isolation
  - freeze-time
applies_when:
  - Writing or editing a request spec that counts requests until Rack::Attack answers 429
  - A throttle spec passes alone but fails in CI
---

# Isolate Rack::Attack specs with a fresh store, a restore, and a frozen clock

## Context

Rack::Attack counts requests in a cache store. In specs, that store lives for the whole test process unless a spec replaces it. `spec/requests/rack_attack/auth_throttle_spec.rb` used to reuse the store created at boot, clear it in `before`, and force `Rack::Attack.enabled = false` in `after`. It also ran on the real clock.

In CI the signup example failed 3 of 3 runs: the sixth signup got 422 instead of 429. Run alone or in a local parallel run, it passed. The exact cause was never reproduced locally. The fix removed every input that can differ between CI and a local run.

## Solution

Use an `around` hook that saves, replaces and restores both values, and freezes time for the whole example:

```ruby
around do |example|
  enabled = Rack::Attack.enabled
  store = Rack::Attack.cache.store
  Rack::Attack.enabled = true
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  freeze_time { example.run }
ensure
  Rack::Attack.enabled = enabled
  Rack::Attack.cache.store = store
end
```

This is the same save-and-restore shape the sibling throttle specs already use. Do not clear the shared store, and do not force `enabled = false` afterwards; set back whatever was there before.

After changing a throttle spec, raise the limit by one in `config/initializers/rack_attack.rb` for a moment and confirm the spec fails. Then restore the initializer. This proves the spec still catches a broken throttle.

## Why it matters

- A shared store carries counters from other specs into this one, and clearing it changes the state other specs see.
- Forcing `enabled = false` at the end changes later specs in the same process, depending on file order.
- Rack::Attack keys each counter on `Time.now.to_i / period`. A burst that starts just before a minute boundary splits across two counters, so the sixth request is not throttled.

Each of these depends on file order or wall-clock time, which is why the failure shows only in CI.

## Evidence

- PR #166 replaces the `before`/`after` hooks in `spec/requests/rack_attack/auth_throttle_spec.rb` with the `around` hook above. The hook's comment states the period keying on `Time.now.to_i / period` and the reason for restoring both values.
- Issue #157 records the CI failure: 429 expected, 422 received, red in 3 of 3 base runs.
- The PR body reports the spec run with the signup limit temporarily raised to 6 ended with 8 failures, all signup examples.
- Graded speculative: the PR states the CI cause was not confirmed locally, and whether the change turns CI green is decided by its own checks, which had not finished.

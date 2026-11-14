---
module: testing
date: 2026-11-14
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - configuration
  - initializers
tags:
  - initializer-specs
  - config-x
  - hard-coded-literal
  - boot-check
applies_when:
  - A spec checks that an initializer or boot code reads a per-environment setting
  - The test environment's value equals the literal the spec asserts
---

# Swap a setting to a distinct value to prove an initializer reads it

## Context

In PR #288, `config/environments/test.rb` declares `config.x.default_base_url = "http://example.com"`. A boot spec loaded `config/initializers/omniauth_full_host.rb` and expected `OmniAuth.config.full_host` to equal that value.

That spec also passes if the initializer hard-codes `"http://example.com"` and ignores the setting. Development and production would then send OAuth callbacks to `example.com`, and no test would fail.

## Solution

Keep the check against the declared test value. Add one example that sets the setting to a value no code path holds as a literal, reloads the initializer, and expects that value. Restore the setting in `ensure`:

```ruby
original = Rails.configuration.x.default_base_url
ENV.delete("APP_BASE_URL")
Rails.configuration.x.default_base_url = "https://boot-check.test"

load initializer_path

expect(OmniAuth.config.full_host).to eq("https://boot-check.test")
ensure
  Rails.configuration.x.default_base_url = original
```

The same idea holds for any code under test that should read a setting: when its test value equals the expected literal, the spec needs a second, distinct value.

## Why it matters

Unit tests of a resolver prove it uses the fallback it is given. They do not prove the boot line passes the real setting in. Only a spec that varies the setting can tell "reads the setting" from "happens to match it". A reviewer should ask, for any boot or config spec: would this still pass if the code returned the test value as a literal?

## Evidence

- PR #288 adds the example "takes the fallback from config.x.default_base_url rather than a fixed value" in `spec/initializers/omniauth_full_host_spec.rb`, beside the example that compares against the declared `http://example.com`.
- The build review of PR #288 found that a hard-coded `"http://example.com"` in the initializer's last line would pass every earlier spec. After the fix, the author replaced that argument with the literal and ran `bundle exec rspec spec/initializers/omniauth_full_host_spec.rb`: 9 examples, 1 failure, the new "takes the fallback from config.x.default_base_url rather than a fixed value" example.

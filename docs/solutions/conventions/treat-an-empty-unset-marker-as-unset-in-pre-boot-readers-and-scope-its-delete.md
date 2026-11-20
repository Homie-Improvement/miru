---
module: timekeeping_demo
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - config/application.rb
  - spec/spec_helper.rb
  - spec/support/timekeeping/owner_state.rb
tags:
  - dotenv
  - env-marker
  - boot-order
  - regression-children
applies_when:
  - A parent process sends an environment key set to "" so dotenv cannot refill it, and the app deletes the empty value after dotenv loads
  - Some code reads that key before Rails boots, for example spec/spec_helper.rb loaded by .rspec
---

# Treat an empty "unset" marker as unset in pre-boot readers, and scope its delete

## Context

The `bin/timekeeping-demo regression` command runs a switches_owner report pass. That pass must run with no owner state. It now sends `TIMEKEEPING_OWNER_STATE` set to "" instead of removing the key, because dotenv fills only absent keys. `config/application.rb` deletes the empty value right after dotenv loads. This is the same pattern the file already uses for `DATABASE_URL`.

That delete runs at one point in the boot order. Code that reads the key earlier still sees the raw "". `spec/spec_helper.rb` decides `fail_if_no_examples` before Rails boots. It used `ENV.key?("TIMEKEEPING_OWNER_STATE")`, so it would count "" as a selected state. The report pass would then fail whenever it found no tagged example, and the regression code treats that result as a normal "none".

## Solution

- List every reader of the key, and note whether it runs before or after the delete. Make each pre-boot reader treat "" as unset. In `spec/spec_helper.rb` the condition is now `!ENV.fetch("TIMEKEEPING_OWNER_STATE", "").empty?`.
- Gate the delete on the marker's context, not only on the empty value: `if ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_OWNER_STATE"] == ""`. The harness in `spec/support/timekeeping/owner_state.rb` treats a blank value as a mistake and raises at load. Outside a regression child, a blank value still reaches that check.
- Test both halves with real child processes. One child boots with "" and `TIMEKEEPING_REGRESSION=1`, and a filter that matches nothing must still pass. Another child boots with "" and no regression flag, and it must fail at load. The probe helper must clear `TIMEKEEPING_REGRESSION` explicitly, so a probe never inherits regression-child status from the run that starts it.

## Why it matters

An empty marker splits one fact ("no state") across two places in the boot order. A reader that runs before the delete silently disagrees with one that runs after it. If the delete is not limited to regression children, it hides every blank value. The guard against a misspelled setting then stops working, and the only unit test of a blank value never goes through boot, so nothing fails.

## Evidence

- PR #448 changes `spec/spec_helper.rb` from `ENV.key?("TIMEKEEPING_OWNER_STATE")` to `!ENV.fetch("TIMEKEEPING_OWNER_STATE", "").empty?`. Its comment says the empty value marks the switches_owner pass, which "may find no example".
- `config/application.rb` in PR #448 deletes the empty value only when `TIMEKEEPING_REGRESSION == "1"`. Its comment says a blank value set anywhere else "still reaches the harness and is reported there".
- `spec/meta/timekeeping_regression_spec.rb` adds the example "a regression child with an empty TIMEKEEPING_OWNER_STATE boots with no state and does not fail when its filters leave no example".
- `spec/meta/timekeeping_owner_state_spec.rb` adds "with TIMEKEEPING_OWNER_STATE empty outside a regression child the run fails at load naming the three values". Its `run_probe` now sets `"TIMEKEEPING_REGRESSION" => nil`. In review, this example passed. It failed when the `TIMEKEEPING_REGRESSION` half of the `config/application.rb` condition was removed.

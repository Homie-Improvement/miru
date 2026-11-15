---
module: spec/initializers
date: 2026-11-15
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - AppBaseUrl
  - spec/support
tags:
  - rspec
  - around-hook
  - shared-spec-helper
  - global-state
  - app-base-url
applies_when:
  - Replacing inline save-and-restore code with a shared spec helper
  - Merging an outer restore-only hook with an inner hook that swaps a setting
  - A spec file has examples that compare a global setting with a separate fallback value
---

# Keep a swapped-setting hook in its original group when you move it to a shared helper

## Context

`with_app_base_url(env:, default:)` in `spec/support/app_base_url_helpers.rb` saves, swaps and restores two process-wide values: `ENV["APP_BASE_URL"]` and `Rails.configuration.x.default_base_url`. Before this helper, `spec/initializers/app_base_url_spec.rb` had two hooks:

- an outer `around` hook that only saved and restored both values for every example;
- a `before` hook inside `describe ".current"` that set the default to `https://boot-check.test`.

One helper call can do both jobs, so the natural move is a single outer `around` hook. That move also swaps the default for the `.resolve` examples, which used to run with the test default `http://example.com`. The `.resolve` examples pass an explicit fallback of `https://boot-check.test`. After the move, the global default and that fallback were the same string. The example `resolve picks a set APP_BASE_URL, else the per-environment fallback, without trailing slashes` still passed, but it could no longer catch code that returns the global setting instead of the fallback it was given.

## Solution

Put the helper call where the old swap was, not where the old restore was:

```ruby
describe ".current" do
  # The .resolve examples stay outside this hook so the setting there differs from their fallback.
  around do |example|
    with_app_base_url(env: nil, default: "https://boot-check.test") { example.run }
  end
```

The outer restore-only hook can go away. The examples outside `.current` do not change either global, so nothing is left to restore for them.

The general rule: a helper that both restores and swaps carries the swap with it. When you replace a restore-only hook and a swap hook with one helper call, place it at the scope of the swap. Then check every example in that scope: does it compare the swapped value with a different value of its own? If it does, the swapped value and that other value must stay different.

## Why it matters

A test that proves code reads source A and not source B only works while A and B hold different values. If a refactor makes them equal, the test still passes when the code reads the wrong source. Nothing fails, so neither a test run nor a quick look at the diff shows the lost check. This is easy to miss in a cleanup pull request that claims to change no behaviour.

## Evidence

- PR #307 adds `with_app_base_url` in `spec/support/app_base_url_helpers.rb` and moves `spec/initializers/app_base_url_spec.rb` onto it.
- In that pull request, `spec/initializers/app_base_url_spec.rb` removes the outer `around` hook and the `.current` `before` hook. It adds one `around` hook inside `describe ".current"`, with the comment: "The .resolve examples stay outside this hook so the setting there differs from their fallback."
- A code review in round 3 of PR #307 flagged the first version, which put the hook on the outer describe. The review noted that the outer hook made the global default equal to the `.resolve` examples' expected fallback, `https://boot-check.test`. The fix moved the hook into `.current`. The author ran `bundle exec rails runner -e test 'puts Rails.configuration.x.default_base_url'`, which printed `http://example.com`. A random-order run of `spec/initializers/app_base_url_spec.rb` and `spec/contracts/app_base_url_helpers_spec.rb` then reported 12 examples and 0 failures.

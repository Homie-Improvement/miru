---
module: spec/meta
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - spec/support/timekeeping
  - spec/fixtures/timekeeping_harness
tags:
  - dotenv
  - subprocess
  - negative-control
  - test-harness
applies_when:
  - A spec launches a child process to prove that a local dotenv file cannot set a key in it
  - The child boots from a temporary app tree built by TimekeepingDotenvTree
---

# Prove the dotenv file reached the child before trusting a dotenv isolation pass

## Context

Some specs here start a child `rspec` process and check that a local `.env` file cannot select a value in it. For example, a developer's `TIMEKEEPING_OWNER_STATE` must not reach the unset-owner-state probe. These specs boot the child in a temporary app tree whose `.env.test.local` names a state. Then they expect the child to pass with no state selected.

The trap is that the pass is the same outcome you get when dotenv never read the file. That happens if the child booted from the real checkout instead of the tree, or if the file was never loaded for another reason. A green run then proves nothing about isolation.

## Solution

Give every dotenv isolation proof three parts:

1. **A marker in the dotenv file.** The tree's file sets a second key the launch never sets, here `TIMEKEEPING_DOTENV_PROBE=loaded`. Pass `TIMEKEEPING_DOTENV_TREE` (the tree's `File.realpath`) to the child.
2. **A check inside the child, before the real assertion.** When `TIMEKEEPING_DOTENV_TREE` is set, the child asserts the marker is `"loaded"` and that `Rails.root` starts with the tree path. Only then does it check that no state is selected.
3. **Two controls in the parent spec.** One launch removes the owner-state key (passes `nil`) and must fail with `1 example, 1 failure`, which shows the file's value really reaches the child. Another writes a file without the marker and must fail, which shows the marker check is live.

Also check that the checkout's `.env*` file list is unchanged after the run, so the file lived only in the temporary tree.

## Why it matters

Without the marker and the controls, a broken tree build or a wrong `chdir` turns the isolation spec into a test that always passes. The fix it guards (sending an empty value as a regression child instead of removing the key) could then regress back to `nil` with no failing test. The removed-key control is what shows the empty-value launch, and not luck, keeps the dotenv value out.

## Evidence

- PR #456 adds the marker check to `spec/fixtures/timekeeping_harness/unset_owner_state_probe.rb`: under `ENV.key?("TIMEKEEPING_DOTENV_TREE")` it expects `TIMEKEEPING_DOTENV_PROBE` to equal `"loaded"` and `Rails.root` to start with the tree path, before `TimekeepingOwnerState::SELECTED` is checked.
- In `spec/meta/timekeeping_owner_state_spec.rb`, PR #456 adds the context "in a temporary app tree whose dotenv file names an owner state" with three examples: the `run_unset_probe` pass that also compares the checkout's `.env*` glob before and after, the removed-key launch through `run_probe("unset_owner_state_probe.rb", nil, root:, env:)` that must fail, and the no-marker file that must fail.
- PR #456 moves `TimekeepingDotenvTree` unchanged from `spec/meta/timekeeping_regression_spec.rb` to `spec/support/timekeeping/dotenv_tree.rb`, so both meta specs build the temporary tree from one copy.

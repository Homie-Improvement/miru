---
module: ci
date: 2026-11-20
problem_type: design_pattern
component: development_workflow
severity: medium
audience: both
related_components:
  - testing_framework
tags:
  - github-actions
  - ci-triggers
  - release-branches
  - pull-request-trigger
applies_when:
  - A workflow job condition skips test jobs on pushes to branches outside a release list
  - A release branch is added to or removed from the job condition or the pull_request trigger
---

# List every push release branch in the pull request trigger when feature pushes skip tests

## Context

The `CI Test Suite` workflow in `.github/workflows/validations.yml` runs on every branch push (`branches: ["**"]`). To save CI minutes, the test jobs now skip a push unless the branch is `develop`, `main`, `stable-3-0` or `production`. A feature branch is then expected to get the full suite from its pull request run instead.

That expectation holds only if the `pull_request` trigger fires for the branch the pull request targets. Before the fix, the trigger listed `[develop, main, production]`. A hotfix branch with a pull request into `stable-3-0` got no test run at all: its push run skipped the tests, and its pull request started no run.

## Solution

Keep the two branch lists in step:

- The `pull_request.branches` list must contain every branch in the job condition's release list (`full_suite_condition`).
- A comment on the trigger says why, so whoever edits one list sees the other.
- The meta spec checks it: every release branch missing from `pull_request.branches` adds a problem `"pull requests into <branch> run no test jobs"`.

A job `if` cannot feed a trigger filter, so the two lists cannot share one literal. The spec is the backstop that keeps them equal.

## Why it matters

The failure is silent. Nothing goes red: the push run shows skipped jobs, which branch protection treats as passed, and no pull request run exists to fail. Untested code then merges into a release branch. Any future change that adds a release branch to the condition, or narrows the trigger, reopens the same gap.

## Evidence

- PR #490 changes `.github/workflows/validations.yml`: `pull_request.branches` goes from `[develop, main, production]` to `[develop, main, stable-3-0, production]`, with a comment saying it must list every release branch in `full_suite_condition`.
- In the same file the shared condition skips pushes outside `fromJSON('["develop","main","stable-3-0","production"]')`.
- `spec/meta/ci_spec_coverage_spec.rb` adds the check in `feature_branch_skip_problems` and the example `fails when pull requests into a release branch no longer run the workflow`, which removes `stable-3-0` from the trigger and expects `"pull requests into stable-3-0 run no test jobs"`.
- Review of PR #490 found the gap for branches whose pull requests target `stable-3-0`; the author's run of `SPEC_OPTS= bundle exec rspec spec/meta/ci_spec_coverage_spec.rb` reported 188 examples, 0 failures across the two meta specs after the fix.

---
module: ci
date: 2026-11-21
problem_type: design_pattern
component: development_workflow
severity: high
audience: both
related_components:
  - testing_framework
tags:
  - ci
  - spec-selection
  - fail-closed
  - required-check
  - rspec
applies_when:
  - A CI step chooses which specs to run from the files a change touches
  - The step backs a required check that must report success when nothing relevant changed
---

# Fail a diff-based spec selector on git errors, and never run rspec with no files

## Context

The `timekeeping-alerts-live` job now runs only the live specs a change touches. A script picks them: `script/ci/timekeeping_live_specs.rb`. The issue required the check to pass with a clear line when nothing is selected, so a required check never hangs. That green path is easy to reach by accident. Two failures land on it:

- A failed `git fetch` or `git diff` returns no paths. An empty list then reads as "no live spec touched", and the check passes with nothing run.
- `bundle exec rspec` with no file arguments runs the whole suite, not zero specs.

## Solution

Keep three outcomes apart and give each its own exit:

1. **The lookup failed.** Any non-zero git exit raises `GitError`. A missing `GITHUB_BASE_REF` on a pull request raises `ArgumentError`. `ConfigError` is raised when the workflow's pull_request branch list does not include main, or when a live spec reads TIMEKEEPING_LIVE through a gate the script does not recognise. `run` rescues all three, writes the cause to stderr and returns `1`. It never prints the no-spec line. A workflow file that cannot be read or parsed raises the YAML loader's own error instead. `run` does not rescue that error, so the script does not return its own status of 1 in that case.
2. **The selection is really empty.** Print `No live Timekeeping spec was selected for this change.` and return `0` without calling rspec.
3. **Specs were selected.** Call `exec("bundle", "exec", "rspec", *specs)`. Because `exec` replaces the process, the step's exit status is rspec's own. Passing each path as its own argument means no shell ever parses a file name taken from the diff.

Also, only pass rspec paths that are in the on-disk inventory: `(changed_paths & live_specs).sort`. Paths from a pull request's diff come from outside. Intersecting them with known files drops deleted specs, `../` paths and names with shell syntax in them.

Release-branch pushes and manual runs never compute a diff (`comparison_base` returns `nil`). A broken diff therefore cannot shrink those runs.

## Why it matters

A required check that turns green when its input could not be read is worse than no check. It tells reviewers the live proofs passed when none ran. The opposite mistake, calling rspec with an empty list, quietly turns a short job into a full-suite run on every unrelated change. Keeping "could not decide", "decided nothing" and "decided these" as separate exits stops both.

## Evidence

- PR #529 adds `script/ci/timekeeping_live_specs.rb`. Its `run` method rescues `GitError, ConfigError, ArgumentError` and returns `1`. It prints `NO_SPEC_MESSAGE` and returns `0` only when `specs.empty?`, after the comment `# rspec with no file arguments would run the whole suite.` `exec_rspec` calls `exec("bundle", "exec", "rspec", *specs)`.
- `spec/scripts/ci/timekeeping_live_specs_spec.rb` in the same pull request pins each outcome. One example has a diff that raises `GitError`: it expects a non-zero status, no rspec call and no no-spec line. One has an empty selection: it expects status 0 and no rspec call. One checks that hostile diff paths never reach rspec. One runs the real script with a stand-in `bundle` that exits 3: it expects exit status 3 and the argument list `exec`, `rspec` plus the three live specs.
- `.github/workflows/validations.yml` in this pull request changes the live step's run line to `ruby script/ci/timekeeping_live_specs.rb`.

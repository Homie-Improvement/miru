---
module: ci
date: 2026-11-21
problem_type: convention
component: development_workflow
severity: medium
audience: both
related_components:
  - tooling
tags:
  - git
  - shallow-clone
  - github-actions
  - changed-files
  - yaml
applies_when:
  - A CI step must list the files a pull request or branch push changed
  - The job uses the default shallow actions/checkout and its setup steps must not change
  - "Ruby code reads the workflow's on: triggers with YAML"
---

# Fetch the base and use a three-dot diff to list changed files in a shallow CI checkout

## Context

The default `actions/checkout` clones one commit, with no base branch and no history. The issue forbade changing the live job's setup steps, so the checkout could not ask for full history. The selector in `script/ci/timekeeping_live_specs.rb` still needed the change's own files.

## Solution

Do the history work inside the step that needs it (`changed_paths`):

1. Check `git rev-parse --is-shallow-repository`. Add `--unshallow` to the fetch only when it prints `true`. Git refuses `--unshallow` on a complete clone.
2. Fetch the base explicitly: `git fetch --no-tags --quiet [--unshallow] origin +refs/heads/<base>:refs/remotes/origin/<base>`.
3. List files with `git diff --name-only --no-renames -z origin/<base>...HEAD`. The three dots diff from the merge base, so commits main gained after the branch was cut do not count. `--no-renames` reports a rename as a delete plus an add. The old path can then still match a full-set prefix, and the new path is the one selected. `-z` keeps odd file names intact.
4. Choose the base by event. A `pull_request` has `GITHUB_BASE_REF`. A `push` does not say where a feature branch was cut from, so it diffs against `origin/main`. That can select more specs, never fewer.

A second trap is in reading the workflow. The selector reads the release-branch list from the workflow's `on.pull_request.branches`, so the list stays written once. Ruby's YAML loader follows YAML 1.1 and loads the bare key `on` as the boolean `true`. The script reads `workflow.fetch(true) { workflow["on"] }`, and it raises `ConfigError` if the list does not include `main`.

## Why it matters

Without the fetch, the diff fails on CI or compares against the wrong commit. A two-dot diff picks up unrelated files from main and runs the wrong specs. `workflow["on"]` returns nil without an error. Code that falls back to an empty list there quietly loses the release branches.

## Evidence

- PR #529 adds `changed_paths`, `comparison_base` and `full_run_branches` in `script/ci/timekeeping_live_specs.rb`, with the shallow check, the explicit refspec fetch, the `...HEAD` diff, and the comment `# YAML 1.1 reads the bare key \`on\` as true.`
- `spec/scripts/ci/timekeeping_live_specs_spec.rb` in this pull request builds a local origin, adds a commit on main after the branch was cut, and expects `changed_paths("origin/main")` to list only the branch's three paths. It then repeats this from a `--depth 1` clone over `file://` that reports `is-shallow-repository` as `true`, and gets the same paths. Another example reads the real workflow and expects `develop`, `main`, `stable-3-0` and `production`.
- `.github/workflows/validations.yml` in this pull request leaves the checkout step unchanged. `spec/meta/ci_spec_coverage_spec.rb` asserts that the checkout step has no `with` key.

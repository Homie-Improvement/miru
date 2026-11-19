---
module: ci
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - bin/parallel_test
  - .github/workflows/validations.yml
tags:
  - parallel-tests
  - ci
  - runtime-log
  - spec-coverage
applies_when:
  - Moving a slow spec directory out of the `Running tests` parallel step into its own job
  - Changing which files `bin/parallel_test` excludes
---

# Exclude a spec directory from parallel runs through one list, and guard its new home

## Context

`bin/parallel_test` runs the suite with `parallel_rspec`. It makes two separate decisions from the set of spec files:

- the `--exclude-pattern` regex it passes to `parallel_rspec`, which decides which files run;
- `runtime_log_usable?`, which adds `--group-by runtime` only when the cached runtime log covers every file that will run.

`parallel_rspec` splits work by whole file. One heavy directory, such as `spec/lib/timekeeping/handoff`, whose example groups reload the two-tenant seed, can keep one of the two processes busy until the job's 60-minute limit. The fix was to move that directory into its own job. There are two quiet ways to get that move wrong.

## Solution

1. Build the excluded directories once and use that one value in both places. `excluded_prefixes` turns `--exclude-dir` paths, plus `spec/system` and `spec/system_skip`, into prefixes ending in `/`. `exclude_pattern` and `spec_files_for` both read that result. If the coverage count still includes the excluded files, a log written by the parallel step, which never runs them, is always rejected as stale. The split then falls back to file size, which is the imbalance you were trying to remove.
2. Anchor and escape the pattern: `^(?:spec/system/|...)` built with `Regexp.escape`. The trailing `/` stops `spec/lib/timekeeping/handoff` from also excluding `handoff_extra/` or `handoffs_spec.rb`. Escaping stops a `.` from matching any character.
3. Emit no `--exclude-pattern` when the list is empty (the `-i` run). An empty `^(?:)` pattern matches every path, so no specs would run.
4. Refuse `--exclude-dir` together with explicit spec paths. Explicit paths go to `parallel_rspec` as given, with no pattern, so the flag would be ignored silently.
5. Add each excluded directory's new job to the meta guard in `spec/meta/ci_spec_coverage_spec.rb`. The guard reads every `--exclude-dir` from the parallel step and fails unless some other job has an `rspec <dir>` step, with no `continue-on-error` on either that step or its job.

## Why it matters

An exclusion drops specs from the main job by design, so nothing in the main job can notice when they stop running anywhere. A green `Running tests` check then proves less than it did before. A coverage count that does not match the run hides a second problem: grouping by runtime silently turns off, and nobody sees an error. Checking `continue-on-error` on the job alone is not enough. Plan review found that a step-level `continue-on-error: true` would still let failures pass, so the guard checks both levels.

## Evidence

- PR #390 changes `bin/parallel_test`. It adds `SYSTEM_SPEC_DIRS`, `excluded_prefixes`, `exclude_pattern` and the repeatable `--exclude-dir` option. It also adds the abort when `--exclude-dir` is combined with spec paths, and it passes `excluded_prefixes:` to `spec_files_for`.
- `spec/bin/parallel_test_spec.rb` (new in PR #390) tests six things: the prefix boundary (`handoff_extra`, `handoffs_spec.rb` not matched); a plain run with no `--exclude-dir` still excludes only `spec/system` and `spec/system_skip`; escaping (`spec/a.b` does not match `spec/aXb`); no pattern under `-i`; refusal with explicit paths; and `--group-by runtime` when the log covers exactly the non-excluded files.
- `spec/meta/ci_spec_coverage_spec.rb` (new in PR #390) defines `uncovered_excluded_dirs`. Its negative cases set `continue-on-error` on the step and on the job, remove the `timekeeping-handoff` job, and point that job at another directory.
- `.github/workflows/validations.yml` in PR #390 adds `--exclude-dir spec/lib/timekeeping/handoff` to the parallel step and adds the `timekeeping-handoff` job, which runs `bundle exec rspec spec/lib/timekeeping/handoff`.
- The author compared the old pattern `spec/(system|system_skip)/` with the new anchored pattern over all 724 spec files. Both matched the same files.

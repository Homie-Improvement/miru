---
module: ci
date: 2026-11-19
problem_type: convention
component: development_workflow
severity: medium
audience: both
related_components:
  - testing_framework
tags:
  - parallel-tests
  - parallel-rspec
  - github-actions
  - matrix
  - sharding
applies_when:
  - Splitting a slow spec directory across GitHub Actions matrix legs with parallel_rspec
  - Changing the -n value or the matrix list of a sharded spec job
---

# Tie parallel_rspec matrix shards to -n and the matrix group selector

## Context

The handoff specs under `spec/lib/timekeeping/handoff` used to run in one job and outgrew its 60-minute limit. Now each matrix leg runs one group of files:

```yaml
strategy:
  fail-fast: false
  matrix:
    group: [1, 2, 3]
...
run: bundle exec parallel_rspec spec/lib/timekeeping/handoff -n 3 --only-group ${{ matrix.group }}
```

This covers every file exactly once only if three facts hold together. Every leg must split the same files the same way; the workflow comment says parallel_tests splits by file size. The matrix list must equal 1 to the `-n` value. And each leg must select its own group through `${{ matrix.group }}`.

## Solution

- Change `-n` and the matrix `group` list together. The matrix must list exactly `1..n`.
- Always pass `--only-group ${{ matrix.group }}`, exactly once. A hard-coded group makes every leg run that group, and the other groups never run. With no selector, every leg runs every file.
- Set `fail-fast: false`, so one failing leg does not cancel the others and hide their failures.
- Keep the spec directory right after the `rspec` command, so the coverage guard's regex `rspec\s+<dir>(\s|\z)` still finds the step.
- With one group selected, parallel_rspec runs it as its first process with an empty `TEST_ENV_NUMBER`. The leg then uses the database that `bundle exec rails db:test:prepare` built, so it needs no per-process databases.

Guard these rules in `spec/meta/ci_spec_coverage_spec.rb`. Read `n` from the run text, compare the matrix with `(1..n).to_a`, require `fail-fast` to be false, and require the selector.

## Why it matters

Each of these mistakes still gives green legs. A shard that never ran reports nothing, so missing coverage looks the same as passing coverage. A missing selector triples the run time and does not fail. The two numbers live in different places in the YAML, so they drift apart when someone tunes the shard count.

## Evidence

- PR #423 changes the `timekeeping-handoff` job in `.github/workflows/validations.yml` to a `group: [1, 2, 3]` matrix with `fail-fast: false`. The run step becomes `parallel_rspec ... -n 3 --only-group ${{ matrix.group }}`. Comments in the job say the matrix must list 1 to the `-n` value, and that one selected group runs with an empty `TEST_ENV_NUMBER`.
- PR #423 adds examples to `spec/meta/ci_spec_coverage_spec.rb`. They drop group 3, set `fail-fast` to true, hard-code `--only-group 1`, and remove the selector. Each example expects one problem message; the hard-coded and missing selector examples share the same message, "the handoff run does not select its group with --only-group ${{ matrix.group }}".
- Review of this change found that the first version of the guard passed when the selector was hard-coded or missing. That is why the selector check was added.
- The split by file size and the empty `TEST_ENV_NUMBER` are parallel_tests behavior. They are stated in this change's workflow comments, not shown by its tests. The checks at the pull request's head commit reported no failure.
